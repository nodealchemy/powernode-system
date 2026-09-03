# frozen_string_literal: true

require "rails_helper"

# IMP-d2f87ffa8733 — the fleet-wide half of IMP-a00997333d8f.
#
# That fix mapped two refusal classes on ONE verb (system_provision_instance) to
# an application-level envelope at Ai::Tools::SystemFleetTool#call. The rescue
# is global to #call's action `case`, so the question this task answers is:
# which OTHER custom StandardError subclasses can still escape #call from any
# action, and is each one a REFUSAL (repeating cannot help) or a FAULT (a real
# failure that must keep surfacing as JSON-RPC -32603)?
#
# The enumeration was done by walking every `when "system_*"` arm through the
# tool's own helpers into the services they call, then reading each service's
# entry point for whether it converts its own errors into a Result (most do)
# or lets them propagate. Of the 68+ `< StandardError` declarations under this
# extension's app/services, exactly FOUR propagate to #call unhandled:
#
#   System::Executors::DiskImage::PromotePublication::UnpromotablePublicationError
#     one raise site (promote_publication.rb:21) from system_set_default_disk_
#     image_publication. System::Executors::Base#call re-raises after logging
#     (base.rb:140-142), so the executor's own guard reaches the tool as an
#     exception. The tool pre-checks status == "published" only; #promotable?
#     also needs file_object_id and published_at. On a PUBLISHED row those two
#     are not independently reachable today — published_at is structurally
#     present (see #promotable?'s transition-graph comment) and file_object_id
#     goes nil only via purge!'s shared-FileObject sweep, which #purge! argues
#     cannot arise — so the live route is the row changing between the tool's
#     read and the executor's own `find` (a concurrent purge/retire sweep),
#     the "re-checked at the moment of mutation" case the RollbackPublication
#     class comment documents. The example below constructs the guard-failing
#     row directly, which is what that race lands the executor on.
#   System::Executors::DiskImage::RollbackPublication::UnpromotablePublicationError
#     one raise site (rollback_publication.rb:22) from system_revert_disk_image.
#     Same re-raise path, but reachable outright: the tool pre-checks purged?
#     and file_object_id only, so a :queued or :verifying row that carries an
#     artifact passes the pre-check and is refused on status.
#   System::Identity::GroupAllocator::CapacityExhausted
#   System::Identity::UserAllocator::CapacityExhausted
#     one raise site each (group_allocator.rb:68, user_allocator.rb:75), from
#     system_create_module / system_update_module with a manifest that declares
#     groups:/users:. ManifestImportService#import! rescues only ImportError and
#     RecordInvalid (manifest_import_service.rb:227-230); the allocators raise
#     from #apply_identities (:985, :994) past both.
#
# All four are REFUSALS: the platform will not (or cannot, given a fixed
# 70000..99999 identity range) do what the manifest or publication asks, the
# message says exactly why, and an identical retry raises identically. Left as
# -32603 they read to an agent as a transport fault and are retried without
# bound.
#
# NOT in scope, and why (each verified at its entry point):
#   ManifestImportService::ImportError, Gitops::ApplyService::{StaleConflict,
#   UnsupportedDiff,CompositionConflict}Error, Gitops::RepoSyncService::
#   CredentialShapeError, InstanceControlService::ControlError (never raised),
#   VolumeManagementService::VolumeError (attach-only, rescued at :120),
#   ModuleBuildDispatchService::DispatchError (dispatch_build! rescues; the
#   raising dispatch_closure is reached only from PackageModuleMaterializer,
#   not this tool) — all converted to a Result before the tool sees them.
#   TemplateCloneService::CloneError, InferenceDeploymentService::
#   DeploymentError, AgentFleetMissionService::FleetError, CatalogDiscovery
#   Service::EmbeddingUnavailable, InstancePoolService::PoolError (+subclasses),
#   CiRunnerLeaseService::LeaseError (+subclasses), ModuleBuildPlannerService::
#   PlanningError, Executors::Base::ReplayBaselineError — rescued in the action
#   body that calls them. Skill executors (PlatformDeploy/Resilience/
#   Maintenance/Runbook/CveResponse/AttributeFailure) rescue StandardError in
#   BaseSkillExecutor#execute (:354) and return a Result.
#
# ORACLE: the caller-visible envelope over the real HTTP/JSON-RPC path — the
# controller sets isError at streamable_http_controller.rb:693 only when a
# RESULT hash carries success: false, so a -32603 error object fails the first
# assertion outright. The retry example is the actual defect. The final example
# pins that a genuine fault still yields -32603, bound to a sentinel so it
# cannot pass on some unrelated upstream error.
RSpec.describe "MCP tools/call — system_fleet_tool refusal surface", type: :request do
  let(:mcp_endpoint) { "/api/v1/mcp/message" }

  def call_tool(tool_name, arguments, headers:, id: 1)
    post mcp_endpoint,
         params: { jsonrpc: "2.0", id: id, method: "tools/call",
                   params: { "name" => "platform.#{tool_name}", "arguments" => arguments } }.to_json,
         headers: headers
  end

  def headers_for(user)
    oauth_app = create(:oauth_application, :mcp_client)
    token = create(:oauth_access_token, oauth_app: oauth_app, resource_owner_id: user.id, scopes: "read write")
    { "Authorization" => "Bearer #{token.plaintext_token}", "Content-Type" => "application/json" }
  end

  def tool_payload(body)
    JSON.parse(body.dig("result", "content", 0, "text"))
  end

  # Shared assertions: a RESULT with isError, success:false, the reason, and
  # the machine-readable discriminator — never a JSON-RPC error object.
  def expect_refusal(body, reason:, code:)
    expect(response).to have_http_status(:ok)
    expect(body["error"]).to be_nil,
                             "refusal surfaced as JSON-RPC error #{body.dig('error', 'code')}: " \
                             "#{body.dig('error', 'message')}"
    expect(body.dig("result", "isError")).to be(true)

    payload = tool_payload(body)
    expect(payload["success"]).to be(false)
    expect(payload["error"]).to match(reason)
    expect(payload["refusal_code"]).to eq(code)
    expect(payload["retryable"]).to be(false)
  end

  def expect_same_refusal_on_retry(first, second)
    expect(second["error"]).to be_nil
    expect(second.dig("result", "isError")).to be(true)
    expect(tool_payload(second)).to eq(tool_payload(first))
  end

  # HIER-P2H — both disk-image verbs below are approval-gated now. The guard
  # they exercise fires INSIDE the replayed action body, so the examples opt
  # into Ai::AutonomyGate's :proceed branch (the executor runs inline) and
  # assert the refusal the replay hands back verbatim; a policy row that
  # parks the call is a different, tested-elsewhere envelope.
  def auto_approve_disk_image_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  describe "system_set_default_disk_image_publication on a published row with no live artifact " \
           "(PromotePublication::UnpromotablePublicationError)" do
    let(:operator) { user_with_permissions("system.nodes.read", "system.modules.update") }
    let(:account)  { operator.account }
    let(:headers)  { headers_for(operator) }
    let(:platform) { create(:system_node_platform, account: account) }

    before { auto_approve_disk_image_policy! }
    let(:publication) do
      pub = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      # status stays "published" (the tool's own pre-check passes) but the
      # artifact pointer is gone, which is exactly what #promotable? refuses.
      pub.update_columns(file_object_id: nil)
      pub
    end

    def set_default
      call_tool("system_set_default_disk_image_publication",
                { "publication_id" => publication.id }, headers: headers)
    end

    it "returns an application-level refusal naming the publication, not a transport fault" do
      set_default
      expect_refusal(json_response, reason: /cannot promote publication #{publication.id}/,
                                    code: "publication_unpromotable")
    end

    it "returns the SAME refusal on an identical retry rather than looping" do
      set_default
      first = json_response
      set_default
      expect_same_refusal_on_retry(first, json_response)
    end
  end

  describe "system_revert_disk_image to a never-published row that still has an artifact " \
           "(RollbackPublication::UnpromotablePublicationError)" do
    let(:operator) { user_with_permissions("system.nodes.read", "system.platforms.rollback_disk_image") }
    let(:account)  { operator.account }
    let(:headers)  { headers_for(operator) }
    let(:platform) { create(:system_node_platform, account: account) }

    before { auto_approve_disk_image_policy! }

    let(:target) do
      # Queued (never published) but carrying a file_object: passes the tool's
      # purged?/file_object_id pre-checks and is refused by the executor guard.
      file_object = create(:file_object, account: account, filename: "queued.img",
                                         file_size: 10_485_760, content_type: "application/octet-stream",
                                         checksum_sha256: "b" * 64)
      create(:system_disk_image_publication, account: account, node_platform: platform,
                                             status: "queued", file_object: file_object)
    end

    def revert
      call_tool("system_revert_disk_image",
                { "platform_id" => platform.id, "publication_id" => target.id }, headers: headers)
    end

    it "returns an application-level refusal naming the publication, not a transport fault" do
      revert
      expect_refusal(json_response, reason: /cannot roll back to publication #{target.id}/,
                                    code: "publication_unpromotable")
    end

    it "returns the SAME refusal on an identical retry rather than looping" do
      revert
      first = json_response
      revert
      expect_same_refusal_on_retry(first, json_response)
    end
  end

  describe "system_update_module with a manifest that declares identities the platform cannot allocate" do
    let(:operator)    { user_with_permissions("system.nodes.read", "system.modules.update") }
    let(:account)     { operator.account }
    let(:headers)     { headers_for(operator) }
    # Already buildable (non-blank manifest_yaml) so the authoring reuse gate
    # (#reuse_gate) stands aside and the call reaches ManifestImportService.
    let(:node_module) do
      create(:system_node_module, account: account, name: "identity-mod",
                                  manifest_yaml: "schema_version: 1\nname: identity-mod\n")
    end
    let(:manifest_yaml) do
      <<~YAML
        schema_version: 1
        name: identity-mod
        display_name: "Identity Module"
        description: "Declares one group and one user."
        license: "MIT"
        file_spec:
          - "/etc/identity-mod/**"
        package_spec:
          - "identity-mod"
        dependencies:
          requires: []
          provides: []
        groups:
          - name: ssl-cert
        users:
          - name: identity-svc
      YAML
    end

    before do
      ::System::ModuleUserDeclaration.delete_all
      ::System::ServiceUserGroupMembership.delete_all
      ::System::ServiceUser.delete_all
      ::System::ServiceGroup.delete_all
    end

    def update_module
      call_tool("system_update_module",
                { "module_id" => node_module.id, "manifest_yaml" => manifest_yaml }, headers: headers)
    end

    context "no free GID (System::Identity::GroupAllocator::CapacityExhausted)" do
      before do
        # Drive the REAL raise site (group_allocator.rb:68) by emptying the
        # range the picker searches, rather than stubbing the raise itself.
        allow_any_instance_of(::System::Identity::GroupAllocator).to receive(:pick_gid).and_return(nil)
      end

      it "returns an application-level refusal naming the exhausted range, not a transport fault" do
        update_module
        expect_refusal(json_response, reason: /no free GID/, code: "identity_capacity_exhausted")
      end

      it "returns the SAME refusal on an identical retry rather than looping" do
        update_module
        first = json_response
        update_module
        expect_same_refusal_on_retry(first, json_response)
      end
    end

    context "no free UID (System::Identity::UserAllocator::CapacityExhausted)" do
      before do
        allow_any_instance_of(::System::Identity::UserAllocator).to receive(:pick_uid).and_return(nil)
      end

      it "returns an application-level refusal naming the exhausted range, not a transport fault" do
        update_module
        expect_refusal(json_response, reason: /no free UID/, code: "identity_capacity_exhausted")
      end

      it "returns the SAME refusal on an identical retry rather than looping" do
        update_module
        first = json_response
        update_module
        expect_same_refusal_on_retry(first, json_response)
      end
    end
  end

  # The inverse guard, on one of the newly covered verbs. If the fix had
  # widened the rescue to StandardError, or to Executors::Base's whole raise
  # surface, this would go green in the wrong direction.
  #
  # On system_update_module, deliberately, since HIER-P2H: the promote verb
  # this used to drive is approval-gated now, and Ai::AutonomyGate#evaluate
  # rescues StandardError around the inline replay and answers "Gate
  # evaluation failed: …" as an application-level result — so on a GATED verb
  # a genuine fault never reaches -32603 whatever this tool's rescue chain
  # does. That is the gate's contract for every gated verb on the platform,
  # not this fix's; the ungated module verb is where this tool's own rescue
  # chain is the only thing between the fault and the wire.
  describe "a genuine internal fault on a newly covered verb" do
    let(:operator)    { user_with_permissions("system.nodes.read", "system.modules.update") }
    let(:account)     { operator.account }
    let(:headers)     { headers_for(operator) }
    let(:node_module) do
      create(:system_node_module, account: account, name: "fault-mod",
                                  manifest_yaml: "schema_version: 1\nname: fault-mod\n")
    end
    let(:manifest_yaml) do
      <<~YAML
        schema_version: 1
        name: fault-mod
        display_name: "Fault Module"
        description: "Declares one group."
        license: "MIT"
        file_spec:
          - "/etc/fault-mod/**"
        package_spec:
          - "fault-mod"
        dependencies:
          requires: []
          provides: []
        groups:
          - name: fault-grp
      YAML
    end

    before do
      ::System::ModuleUserDeclaration.delete_all
      ::System::ServiceUserGroupMembership.delete_all
      ::System::ServiceUser.delete_all
      ::System::ServiceGroup.delete_all
      allow_any_instance_of(::System::Identity::GroupAllocator).to receive(:pick_gid)
        .and_raise(NoMethodError, "undefined method `imp_d2f87ffa8733_fault_sentinel' for nil")
    end

    it "still surfaces as JSON-RPC -32603, because it is not a refusal" do
      call_tool("system_update_module",
                { "module_id" => node_module.id, "manifest_yaml" => manifest_yaml }, headers: headers)

      body = json_response
      expect(body.dig("error", "code")).to eq(-32603),
                                           "a genuine fault was converted into an application-level result: " \
                                           "#{body['result'].inspect}"
      expect(body["result"]).to be_nil
      expect(body.dig("error", "message")).to include("imp_d2f87ffa8733_fault_sentinel")
    end
  end
end
