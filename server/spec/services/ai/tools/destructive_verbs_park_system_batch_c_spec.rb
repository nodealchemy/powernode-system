# frozen_string_literal: true

require "rails_helper"

# c13-2 batch E-C, the last extension batch. Three verbs are require_approval
# (drain_instance_pool, instance_hold, instance_release_hold) and park for the
# caller's approval, replaying as the original caller. Two are HUMAN-ONLY
# (rotate_vault_transit_pepper, acme_revoke_certificate): they park for a
# person's own session whoever calls, and run only as the person who confirms,
# who must hold the tool's own permission at park time AND at replay. Every
# example asserts the row or the service call as well as the envelope.
RSpec.describe "c13-2 batch E-C destructive system verbs park", type: :service do
  let(:account) { create(:account) }
  let!(:owner) { create(:user, account: account) } # first user: account owner

  let(:approver) { create(:user, account: account, permissions: %w[ai.autonomy.approve ai.agents.read]) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:node) { create(:system_node, account: account, node_template: template) }

  FLEET = Ai::Tools::SystemFleetTool
  ACME = Ai::Tools::SystemAcmeTool

  # Service calls the verbs would make, recorded by stubs so an example can see
  # whether anything ran.
  let(:acted) { [] }

  before do
    seen = acted
    allow(::System::InstancePoolService).to receive(:drain!) { |**kw| seen << [ :drain, kw[:pool]&.id ]; {} }
    allow(::Security::CredentialRestorationService).to receive(:rotate_transit_pepper!) do |**kw|
      seen << [ :rotate, kw ]
      ::Security::CredentialRestorationService::Result.new(
        "ok?": true, rotated_count: 3, skipped_count: 0, failed_count: 0, latest_version: 7, errors: []
      )
    end
    allow(::Acme::CertificateManager).to receive(:revoke!) do |certificate:, reason: nil|
      seen << [ :revoke, certificate.id ]
      ::Acme::CertificateManager::Result.new("ok?": true, certificate: certificate)
    end
  end

  # Restore, never reset!: reset! nils the resolvers the extension engine wires at
  # boot, which silently turns every later instance-principal example in the
  # process into a refusal (system_fleet_tool_inspect_node_spec).
  around do |example|
    orig_instance = ::Mcp::Principal.instance_resolver
    orig_grant = ::Mcp::Principal.tool_grant_resolver
    example.run
  ensure
    ::Mcp::Principal.instance_resolver = orig_instance
    ::Mcp::Principal.tool_grant_resolver = orig_grant
  end

  def user_with(*perms) = create(:user, account: account, permissions: perms)

  def run(klass, params, user:, agent: nil)
    tool = klass.new(account: account, user: user, agent: agent)
    tool.call_origin = "mcp_oauth"
    tool.execute(params: params.with_indifferent_access)
  end

  def expect_parked(result, category, human_only: false)
    expect(result).to include(success: true)
    expect(result[:data]).to include(pending: true)
    expect(result[:data]).to include(requires_human_session: true) if human_only
    operation = Ai::DeferredOperation.find(result[:data][:deferred_operation_id])
    expect(operation.action_category).to eq(category)
    expect(operation.executor_class).to eq("Ai::Executors::DeferredToolCall")
    expect(Ai::ApprovalRequest.find(result[:data][:approval_request_id]).requires_human_session?).to be(true)
    operation
  end

  def confirm!(parked, as: approver, expect_ok: true)
    request = Ai::ApprovalRequest.find(parked[:data][:approval_request_id])
    decided = Ai::Autonomy::ApprovalWorkflowService.new(account: account)
                                                   .approve(request: request, approver: as,
                                                            origin: Ai::ApprovalDecision::REST_SESSION)
    expect(decided).to be(true) if expect_ok
    Ai::DeferredOperation.find(parked[:data][:deferred_operation_id]).reload
  end

  def revoke!(user, permission)
    RolePermission.where(role_id: user.roles.select(:id), permission_name: permission).delete_all
  end

  def pool_in(acct)
    region = create(:system_provider_region, account: acct)
    itype = create(:system_provider_instance_type, account: acct)
    tmpl = create(:system_node_template, account: acct, node_platform: create(:system_node_platform, account: acct))
    ::System::InstancePool.create!(account: acct, node_template: tmpl, name: "p-#{SecureRandom.hex(3)}",
                                   target_size: 0, min_size: 0, max_size: 5, lifecycle_class: "ephemeral",
                                   status: "archived", provider_region: region, provider_instance_type: itype)
  end

  # tool, action, permission, category, human_only
  CASES = [
    { action: "system_drain_instance_pool", tool: FLEET, permission: "system.instances.control",
      category: "system.instance_pool_drain", human_only: false },
    { action: "system_instance_hold", tool: FLEET, permission: "system.instances.control",
      category: "system.instance_hold", human_only: false },
    { action: "system_instance_release_hold", tool: FLEET, permission: "system.instances.control",
      category: "system.instance_hold_release", human_only: false },
    { action: "system_rotate_vault_transit_pepper", tool: FLEET, permission: "system.fleet.autonomy",
      category: "system.vault_pepper.rotate", human_only: true },
    { action: "system_acme_revoke_certificate", tool: ACME, permission: "system.acme.revoke",
      category: "system.acme_cert.revoke", human_only: true }
  ].freeze

  # [params naming the target, -> relation that EXISTS while the verb has not acted]
  def target_for(action)
    case action
    when "system_drain_instance_pool"
      pool = pool_in(account)
      [ { pool_id: pool.id }, -> { acted.none? { |a| a.first == :drain } ? ::Account.where(id: account.id) : ::Account.none } ]
    when "system_instance_hold"
      i = create(:system_node_instance, :running, node: node)
      [ { instance_id: i.id, reason: "offline disk work" }, -> { ::System::NodeInstance.where(id: i.id, ops_hold_at: nil) } ]
    when "system_instance_release_hold"
      i = create(:system_node_instance, :running, node: node)
      i.update!(ops_hold_at: Time.current, ops_hold_reason: "disk work", ops_hold_by_id: owner.id)
      [ { instance_id: i.id }, -> { ::System::NodeInstance.where(id: i.id).where.not(ops_hold_at: nil) } ]
    when "system_rotate_vault_transit_pepper"
      [ { reencrypt_existing: true }, -> { acted.none? { |a| a.first == :rotate } ? ::Account.where(id: account.id) : ::Account.none } ]
    when "system_acme_revoke_certificate"
      cert = create(:system_acme_certificate, :valid, account: account)
      [ { certificate_id: cert.id }, -> { acted.none? { |a| a.first == :revoke } ? ::Account.where(id: account.id) : ::Account.none } ]
    end
  end

  CASES.each do |c|
    describe c[:action] do
      let(:tool_class) { c[:tool] }
      let(:caller_user) { user_with(c[:permission], c[:tool]::REQUIRED_PERMISSION) }
      let(:person) { user_with(c[:permission], c[:tool]::REQUIRED_PERMISSION, "ai.autonomy.approve", "ai.agents.read") }
      let(:target) { target_for(c[:action]) }
      let(:params) { { action: c[:action] }.merge(target.first) }
      let(:intact) { target.last }

      def go(user:, agent: nil) = run(tool_class, params, user: user, agent: agent)

      it "declares the category and executor, #{c[:human_only] ? 'human_only' : 'require_approval, not human_only'}" do
        decl = tool_class.declared_action(c[:action])
        expect(decl).to include(action_category: c[:category], executor_class: "Ai::Executors::DeferredToolCall",
                                gate_context: :deferred_tool_call_context, on_proceed: :deferred_tool_call_result)
        if c[:human_only]
          expect(decl[:human_only]).to be(true)
        else
          expect(decl[:human_only]).to be_falsey
        end
      end

      it "is never seeded at auto_approve or notify_and_proceed (unseeded defaults to require_approval)" do
        seeded = ::System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES[c[:category]]

        expect([ nil, "require_approval" ]).to include(seeded)
      end

      it "parks, leaving the target untouched and acting on nothing" do
        parked = go(user: caller_user)

        expect_parked(parked, c[:category], human_only: c[:human_only])
        expect(intact.call).to exist
        expect(acted).to be_empty
      end

      it "acts on approval, #{c[:human_only] ? 'as the person who confirms it' : 'as the original caller'}" do
        parked = go(user: caller_user)
        expect(intact.call).to exist

        operation = confirm!(parked, as: c[:human_only] ? person : approver)

        expect(operation.status).to eq("completed")
        expect(operation.result.with_indifferent_access).not_to include(success: false)
        expect(intact.call).not_to exist
      end

      if c[:human_only]
        it "does not run when the confirming person lacks #{c[:permission]}" do
          parked = go(user: caller_user)

          request = Ai::ApprovalRequest.find(parked[:data][:approval_request_id])
          decided = Ai::Autonomy::ApprovalWorkflowService.new(account: account)
                                                         .approve(request: request, approver: approver,
                                                                  origin: Ai::ApprovalDecision::REST_SESSION)
          operation = Ai::DeferredOperation.find(parked[:data][:deferred_operation_id]).reload

          # The decision itself is refused: the request stays pending, the
          # operation never runs, and the effect did not happen.
          expect(decided).to be(false)
          expect(request.reload.status).to eq("pending")
          expect(operation.status).to eq("pending")
          expect(operation.result).to be_blank
          expect(intact.call).to exist
          expect(acted).to be_empty
        end
      else
        it "refuses the replay, acting on nothing, when the permission was revoked after parking" do
          parked = go(user: caller_user)
          revoke!(caller_user, c[:permission])

          operation = confirm!(parked)

          expect(intact.call).to exist
          expect(acted).to be_empty
          expect(operation.result.with_indifferent_access).to include(success: false)
          expect(operation.result.with_indifferent_access[:error]).to match(/permission/i)
        end
      end

      it "refuses a caller without the permission, and parks nothing" do
        denied = go(user: user_with(c[:tool]::REQUIRED_PERMISSION))

        expect(denied[:success]).to be(false)
        expect(denied[:error]).to match(/permission denied: #{Regexp.escape(c[:permission])}/)
        expect(Ai::DeferredOperation.count).to eq(0)
        expect(intact.call).to exist
      end

      it "refuses an agent principal with no user, and parks nothing" do
        denied = go(user: nil, agent: create(:ai_agent, account: account))

        expect(denied[:success]).to be(false)
        expect(Ai::DeferredOperation.count).to eq(0)
        expect(intact.call).to exist
      end
    end
  end

  describe "what a parked request and its card carry" do
    it "carries the reencrypt flag only for the pepper rotation, never key material" do
      parked = run(FLEET, { action: "system_rotate_vault_transit_pepper", reencrypt_existing: false },
                   user: user_with("system.fleet.autonomy", FLEET::REQUIRED_PERMISSION))
      operation = expect_parked(parked, "system.vault_pepper.rotate", human_only: true)
      request = Ai::ApprovalRequest.find(parked[:data][:approval_request_id])

      shown = [ operation.params, request.request_data, parked ].to_json
      expect(shown).to include("system_rotate_vault_transit_pepper")
      expect(shown).not_to match(/pepper_value|pepper_material|vault:v\d|ciphertext|plaintext|latest_version/i)
      expect(operation.params.dig("tool_params").keys).to contain_exactly("action", "reencrypt_existing")
    end

    it "names the certificate by id and carries no PEM or key" do
      cert = create(:system_acme_certificate, :valid, account: account)
      parked = run(ACME, { action: "system_acme_revoke_certificate", certificate_id: cert.id, reason: "keyCompromise" },
                   user: user_with("system.acme.revoke", ACME::REQUIRED_PERMISSION))
      operation = expect_parked(parked, "system.acme_cert.revoke", human_only: true)
      request = Ai::ApprovalRequest.find(parked[:data][:approval_request_id])

      shown = [ operation.params, request.request_data ].to_json
      expect(shown).to include(cert.id)
      expect(shown).not_to match(/BEGIN (CERTIFICATE|PRIVATE KEY)|private_key|fullchain/i)
    end
  end

  describe "account scoping at replay (the park does not validate scope, the replay must not reach the row)" do
    it "does not drain another account's pool" do
      other = create(:account)
      foreign = pool_in(other)
      result = run(FLEET, { action: "system_drain_instance_pool", pool_id: foreign.id },
                   user: user_with("system.instances.control", FLEET::REQUIRED_PERMISSION))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = confirm!(result).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil # reached the handler, not refused for permission
      expect(acted).to be_empty
    end

    it "does not hold another account's instance" do
      other = create(:account)
      other_node = create(:system_node, account: other,
                          node_template: create(:system_node_template, account: other,
                                                node_platform: create(:system_node_platform, account: other)))
      foreign = create(:system_node_instance, :running, node: other_node)
      result = run(FLEET, { action: "system_instance_hold", instance_id: foreign.id, reason: "x" },
                   user: user_with("system.instances.control", FLEET::REQUIRED_PERMISSION))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = confirm!(result).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil
      expect(::System::NodeInstance.find(foreign.id).ops_hold_at).to be_nil
    end

    it "does not release a hold on another account's instance" do
      other = create(:account)
      other_node = create(:system_node, account: other,
                          node_template: create(:system_node_template, account: other,
                                                node_platform: create(:system_node_platform, account: other)))
      foreign = create(:system_node_instance, :running, node: other_node)
      foreign.update!(ops_hold_at: Time.current, ops_hold_reason: "theirs", ops_hold_by_id: owner.id)
      result = run(FLEET, { action: "system_instance_release_hold", instance_id: foreign.id },
                   user: user_with("system.instances.control", FLEET::REQUIRED_PERMISSION))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = confirm!(result).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil
      expect(::System::NodeInstance.find(foreign.id).ops_hold_at).not_to be_nil
    end

    it "does not revoke another account's certificate" do
      other = create(:account)
      foreign = create(:system_acme_certificate, :valid, account: other)
      person = user_with("system.acme.revoke", ACME::REQUIRED_PERMISSION, "ai.autonomy.approve", "ai.agents.read")
      result = run(ACME, { action: "system_acme_revoke_certificate", certificate_id: foreign.id },
                   user: user_with("system.acme.revoke", ACME::REQUIRED_PERMISSION))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = confirm!(result, as: person).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil
      expect(acted).to be_empty
    end
  end

  describe "deliberately untouched (held by operator decision)" do
    HELD = {
      "system_upgrade_boot_image" => FLEET,
      "system_drain_instance" => FLEET,
      "system_recycle_pool" => FLEET,
      "system_delete_architecture" => Ai::Tools::SystemArchitectureCatalogTool
    }.freeze

    HELD.each do |action, klass|
      it "leaves #{action} ungated and on the agents' denied list" do
        decl = klass.declared_action(action)

        expect(decl[:executor_class]).to be_nil
        expect(klass.may_park?(decl)).to be(false)
        expect(Ai::ClaudeExport::ThinLoader::DENIED_DESTRUCTIVE_ACTIONS).to include(action)
      end
    end
  end
end
