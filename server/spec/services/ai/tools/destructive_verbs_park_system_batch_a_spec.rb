# frozen_string_literal: true

require "rails_helper"

# c13-2 batch E-A: seven destroy-shaped system verbs. Each is require_approval
# (none human_only), parked through Ai::Executors::DeferredToolCall, with the
# tool's own permission check running BEFORE the park and again at replay.
# Every example asserts the row as well as the envelope.
RSpec.describe "c13-2 batch E-A destructive system verbs park", type: :service do
  let(:account) { create(:account) }
  let!(:owner) { create(:user, account: account) } # first user: account owner

  let(:approver) { create(:user, account: account, permissions: %w[ai.autonomy.approve ai.agents.read]) }

  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }

  after { ::Mcp::Principal.reset! }

  def user_with(*perms) = create(:user, account: account, permissions: perms)

  def run(tool_class, params, user:, agent: nil)
    tool = tool_class.new(account: account, user: user, agent: agent)
    tool.call_origin = "mcp_oauth"
    tool.execute(params: params.with_indifferent_access)
  end

  def expect_parked(result, category)
    expect(result).to include(success: true)
    expect(result[:data]).to include(pending: true)
    operation = Ai::DeferredOperation.find(result[:data][:deferred_operation_id])
    expect(operation.action_category).to eq(category)
    expect(operation.executor_class).to eq("Ai::Executors::DeferredToolCall")
    expect(Ai::ApprovalRequest.find(result[:data][:approval_request_id]).requires_human_session?).to be(true) # destructive: true
    operation
  end

  def approve!(parked)
    request = Ai::ApprovalRequest.find(parked[:data][:approval_request_id])
    decided = Ai::Autonomy::ApprovalWorkflowService.new(account: account)
                                                   .approve(request: request, approver: approver,
                                                            origin: Ai::ApprovalDecision::REST_SESSION)
    expect(decided).to be(true)
    Ai::DeferredOperation.find(parked[:data][:deferred_operation_id]).reload
  end

  def revoke!(user, permission)
    RolePermission.where(role_id: user.roles.select(:id), permission_name: permission).delete_all
  end

  # [label, tool class, action, permission, category, params builder, "still there" check builder]
  CASES = [
    { action: "system_delete_cve", tool: Ai::Tools::SystemFleetTool, permission: "system.fleet.autonomy",
      category: "system.cve.delete" },
    { action: "system_delete_package_repository", tool: Ai::Tools::SystemPackageRepositoryTool,
      permission: "system.package_repositories.delete", category: "system.package_repository.delete" },
    { action: "system_delete_service", tool: Ai::Tools::SystemIngressTool,
      permission: "system.ingress.manage", category: "system.service.delete" },
    { action: "system_delete_template", tool: Ai::Tools::SystemFleetTool,
      permission: "system.templates.delete", category: "system.template.delete" },
    { action: "system_delete_module", tool: Ai::Tools::SystemFleetTool,
      permission: "system.modules.delete", category: "system.module.delete" },
    { action: "system_delete_provider", tool: Ai::Tools::SystemFleetTool,
      permission: "system.providers.delete", category: "system.provider.delete" },
    { action: "system_delete_node", tool: Ai::Tools::SystemFleetTool,
      permission: "system.nodes.delete", category: "system.node.delete" }
  ].freeze

  # The record a verb deletes, and the params that name it.
  def target_for(action)
    case action
    when "system_delete_cve"
      cve = create(:system_cve)
      [ { cve_id: cve.cve_id }, -> { ::System::Cve.where(id: cve.id) } ]
    when "system_delete_package_repository"
      repo = create(:system_package_repository, account: account)
      [ { repository_id: repo.id }, -> { ::System::PackageRepository.where(id: repo.id) } ]
    when "system_delete_service"
      svc = ::Sdwan::Service.create!(account: account, slug: "svc-#{SecureRandom.hex(3)}", name: "Svc",
                                     protocol: "https", backend_host: "10.0.0.5", backend_port: 3000)
      [ { service_id: svc.id }, -> { ::Sdwan::Service.where(id: svc.id) } ]
    when "system_delete_template"
      t = create(:system_node_template, account: account, node_platform: platform_record)
      [ { template_id: t.id }, -> { ::System::NodeTemplate.where(id: t.id) } ]
    when "system_delete_module"
      m = create(:system_node_module, account: account, node_platform: platform_record, category: category)
      [ { module_id: m.id }, -> { ::System::NodeModule.where(id: m.id) } ]
    when "system_delete_provider"
      p = create(:system_provider, account: account)
      [ { provider_id: p.id }, -> { ::System::Provider.where(id: p.id) } ]
    when "system_delete_node"
      n = create(:system_node, account: account, node_template: template)
      [ { node_id: n.id }, -> { ::System::Node.where(id: n.id) } ]
    end
  end

  CASES.each do |c|
    describe c[:action] do
      let(:caller_user) { user_with(c[:permission], c[:tool]::REQUIRED_PERMISSION) }
      let(:target) { target_for(c[:action]) }
      let(:params) { { action: c[:action] }.merge(target.first) }
      let(:remaining) { target.last }

      let(:tool_class) { c[:tool] }

      def go(user:, agent: nil) = run(tool_class, params, user: user, agent: agent)

      it "declares the category and executor, require_approval, not human_only" do
        decl = c[:tool].declared_action(c[:action])
        expect(decl).to include(action_category: c[:category], executor_class: "Ai::Executors::DeferredToolCall",
                                gate_context: :deferred_tool_call_context, on_proceed: :deferred_tool_call_result)
        expect(decl[:human_only]).to be_falsey
      end

      it "parks, leaving the record in place" do
        parked = go(user: caller_user)

        expect_parked(parked, c[:category])
        expect(remaining.call).to exist
      end

      it "deletes on approval, as the original caller" do
        parked = go(user: caller_user)
        expect(remaining.call).to exist

        expect(approve!(parked).status).to eq("completed")
        expect(remaining.call).not_to exist
      end

      it "refuses the replay, keeping the record, when the permission was revoked after parking" do
        parked = go(user: caller_user)
        revoke!(caller_user, c[:permission])

        operation = approve!(parked)

        expect(remaining.call).to exist
        expect(operation.result.with_indifferent_access).to include(success: false)
        expect(operation.result.with_indifferent_access[:error]).to match(/permission/i)
      end

      it "refuses a caller without the permission, and parks nothing" do
        denied = go(user: user_with(c[:tool]::REQUIRED_PERMISSION))

        expect(denied[:success]).to be(false)
        expect(denied[:error]).to match(/permission denied: #{Regexp.escape(c[:permission])}/)
        expect(Ai::DeferredOperation.count).to eq(0)
        expect(remaining.call).to exist
      end

      it "refuses an agent principal with no user, and parks nothing" do
        denied = go(user: nil, agent: create(:ai_agent, account: account))

        expect(denied[:success]).to be(false)
        expect(Ai::DeferredOperation.count).to eq(0)
        expect(remaining.call).to exist
      end
    end
  end

  describe "the parked request carries ids only" do
    it "packs the target id, not the record" do
      node = create(:system_node, account: account, node_template: template)
      parked = run(Ai::Tools::SystemFleetTool, { action: "system_delete_node", node_id: node.id },
                   user: user_with("system.nodes.delete"))
      operation = expect_parked(parked, "system.node.delete")

      packed = operation.params.to_json
      expect(packed).to include(node.id)
      expect(packed).not_to include(node.name)
    end
  end

  describe "account scoping at replay" do
    it "does not delete another account's node even when its id is parked" do
      other = create(:account)
      foreign = create(:system_node, account: other,
                       node_template: create(:system_node_template, account: other,
                                             node_platform: create(:system_node_platform, account: other)))
      result = run(Ai::Tools::SystemFleetTool, { action: "system_delete_node", node_id: foreign.id },
                   user: user_with("system.nodes.delete", "system.nodes.read"))

      # The park does not validate scope: it parks. The replay must not reach the row.
      expect(result.dig(:data, :pending)).to be(true)
      operation = approve!(result)

      replayed = operation.result.with_indifferent_access
      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil # reached the handler, not refused for permission
      expect(::System::Node.where(id: foreign.id)).to exist
    end
  end

  describe "deliberately untouched" do
    it "leaves system_delete_architecture ungated (held by operator decision)" do
      decl = Ai::Tools::SystemArchitectureCatalogTool.declared_action("system_delete_architecture")
      expect(decl[:executor_class]).to be_nil
    end
  end
end
