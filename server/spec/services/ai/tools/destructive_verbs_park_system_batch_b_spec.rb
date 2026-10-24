# frozen_string_literal: true

require "rails_helper"

# c13-2 batch E-B: seven destroy-shaped system fleet verbs. Each is
# require_approval (none human_only), parked through
# Ai::Executors::DeferredToolCall, with the tool's own per-action permission
# check running BEFORE the park and again at replay. Every example asserts the
# row or the service call as well as the envelope.
RSpec.describe "c13-2 batch E-B destructive system fleet verbs park", type: :service do
  let(:account) { create(:account) }
  let!(:owner) { create(:user, account: account) } # first user: account owner

  let(:approver) { create(:user, account: account, permissions: %w[ai.autonomy.approve ai.agents.read]) }
  let(:tool_class) { Ai::Tools::SystemFleetTool }
  let(:floor) { tool_class::REQUIRED_PERMISSION }

  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:node) { create(:system_node, account: account, node_template: template) }

  # stop/reboot reach System::InstanceControlService (ops hold + INV-1 live there);
  # it is stubbed so the example can see whether it ran.
  let(:control_calls) { [] }

  before do
    calls = control_calls
    allow(::System::InstanceControlService).to receive(:execute) do |**kw|
      calls << kw[:action]
      ::System::Runtime::Result.ok(data: {})
    end
    allow(::System::ProvisioningService).to receive(:terminate_instance)
      .and_return(double(success?: true, error: nil))
  end

  after { ::Mcp::Principal.reset! }

  def user_with(*perms) = create(:user, account: account, permissions: perms)

  def run(params, user:, agent: nil, klass: tool_class)
    tool = klass.new(account: account, user: user, agent: agent)
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

  CASES = [
    { action: "system_delete_volume", permission: "system.volumes.delete", category: "system.volume.delete" },
    { action: "system_delete_instance_pool", permission: "system.instances.create", category: "system.instance_pool_delete" },
    { action: "system_destroy_instance", permission: "system.instances.control", category: "system.instance_destroy" },
    { action: "system_terminate_ci_worker", permission: "system.ci_workers.delete", category: "system.ci_worker.terminate" },
    { action: "system_reap_agent_fleet", permission: "system.node_instances.manage", category: "system.agent_fleet.reap" },
    { action: "system_stop_instance", permission: "system.instances.control", category: "system.instance_stop" },
    { action: "system_reboot_instance", permission: "system.instances.control", category: "system.instance_reboot_request" }
  ].freeze

  # [params naming the target, -> relation that EXISTS while the verb has not acted]
  def target_for(action)
    case action
    when "system_delete_volume"
      v = create(:system_provider_volume, account: account)
      [ { volume_id: v.id }, -> { ::System::ProviderVolume.where(id: v.id) } ]
    when "system_delete_instance_pool"
      region = create(:system_provider_region, account: account)
      itype = create(:system_provider_instance_type, account: account)
      pool = ::System::InstancePool.create!(account: account, node_template: template, name: "p-#{SecureRandom.hex(3)}",
                                            target_size: 0, min_size: 0, max_size: 5, lifecycle_class: "ephemeral",
                                            status: "archived", provider_region: region, provider_instance_type: itype)
      [ { pool_id: pool.id }, -> { ::System::InstancePool.where(id: pool.id) } ]
    when "system_destroy_instance"
      i = create(:system_node_instance, :running, node: node)
      [ { instance_id: i.id }, -> { ::System::NodeInstance.where(id: i.id) } ]
    when "system_terminate_ci_worker"
      w = ::Worker.create_worker!(name: "ci-#{SecureRandom.hex(3)}", account: account, roles: [ "ci_worker" ])
      [ { worker_id: w.id }, -> { ::Worker.where(id: w.id).where.not(status: "revoked") } ]
    when "system_reap_agent_fleet"
      mission = fleet_mission
      [ { mission_id: mission.id },
        -> { ::Ai::Mission.where(id: mission.id).where("configuration->'fleet'->'reaped' IS NULL") } ]
    when "system_stop_instance", "system_reboot_instance"
      i = create(:system_node_instance, :running, node: node)
      [ { instance_id: i.id }, -> { control_calls.empty? ? ::Account.where(id: account.id) : ::Account.none } ]
    end
  end

  def fleet_mission
    fleet_template = create(:ai_mission_template, name: "system_agent_fleet", template_type: "system",
                            mission_type: "agent_fleet",
                            phases: [ { "order" => 0, "key" => "reap", "requires_approval" => false,
                                        "job_class" => "AiAgentFleetReapJob" } ],
                            approval_gates: [], rejection_mappings: {})
    instance = create(:system_node_instance, :running, node: node)
    create(:ai_mission, account: account, mission_type: "agent_fleet", mission_template: fleet_template,
                        configuration: { "fleet" => {
                          "plan" => { "size" => 1, "source" => "provision", "reap" => true },
                          "members" => [ { "slot" => 0, "instance_id" => instance.id, "peer_id" => nil } ]
                        } })
  end

  CASES.each do |c|
    describe c[:action] do
      let(:caller_user) { user_with(c[:permission], tool_class::REQUIRED_PERMISSION) }
      let(:target) { target_for(c[:action]) }
      let(:params) { { action: c[:action] }.merge(target.first) }
      let(:intact) { target.last }

      def go(user:, agent: nil) = run(params, user: user, agent: agent)

      it "declares the category and executor, require_approval, not human_only" do
        decl = tool_class.declared_action(c[:action])
        expect(decl).to include(action_category: c[:category], executor_class: "Ai::Executors::DeferredToolCall",
                                gate_context: :deferred_tool_call_context, on_proceed: :deferred_tool_call_result)
        expect(decl[:human_only]).to be_falsey
      end

      it "is never seeded at auto_approve or notify_and_proceed (unseeded defaults to require_approval)" do
        seeded = ::System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES[c[:category]]

        expect([ nil, "require_approval" ]).to include(seeded)
      end

      it "parks, leaving the target in place and acting on nothing" do
        parked = go(user: caller_user)

        expect_parked(parked, c[:category])
        expect(intact.call).to exist
        expect(control_calls).to be_empty
      end

      it "acts on approval, as the original caller" do
        parked = go(user: caller_user)
        expect(intact.call).to exist

        expect(approve!(parked).status).to eq("completed")
        expect(intact.call).not_to exist
      end

      it "refuses the replay, acting on nothing, when the permission was revoked after parking" do
        parked = go(user: caller_user)
        revoke!(caller_user, c[:permission])

        operation = approve!(parked)

        expect(intact.call).to exist
        expect(control_calls).to be_empty
        expect(operation.result.with_indifferent_access).to include(success: false)
        expect(operation.result.with_indifferent_access[:error]).to match(/permission/i)
      end

      it "refuses a caller without the permission, and parks nothing" do
        denied = go(user: user_with(tool_class::REQUIRED_PERMISSION))

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

  describe "the parked request carries ids only" do
    it "packs the instance id, not the record" do
      instance = create(:system_node_instance, :running, node: node)
      parked = run({ action: "system_destroy_instance", instance_id: instance.id },
                   user: user_with("system.instances.control"))
      operation = expect_parked(parked, "system.instance_destroy")

      packed = operation.params.to_json
      expect(packed).to include(instance.id)
      expect(packed).not_to include(instance.name)
    end
  end

  describe "account scoping at replay" do
    let(:other) { create(:account) }
    let(:other_node) do
      create(:system_node, account: other,
             node_template: create(:system_node_template, account: other,
                                   node_platform: create(:system_node_platform, account: other)))
    end

    # The park does not validate scope: it parks. The replay must not reach the row.
    it "does not destroy another account's instance even when its id is parked" do
      foreign = create(:system_node_instance, :running, node: other_node)
      result = run({ action: "system_destroy_instance", instance_id: foreign.id },
                   user: user_with("system.instances.control", floor))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = approve!(result).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil # reached the handler, not refused for permission
      expect(::System::NodeInstance.where(id: foreign.id)).to exist
    end

    it "does not stop another account's instance even when its id is parked" do
      foreign = create(:system_node_instance, :running, node: other_node)
      result = run({ action: "system_stop_instance", instance_id: foreign.id },
                   user: user_with("system.instances.control", floor))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = approve!(result).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil
      expect(control_calls).to be_empty
    end

    it "does not revoke another account's ci worker even when its id is parked" do
      worker = ::Worker.create_worker!(name: "foreign-ci", account: other, roles: [ "ci_worker" ])
      result = run({ action: "system_terminate_ci_worker", worker_id: worker.id },
                   user: user_with("system.ci_workers.delete", floor))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = approve!(result).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil
      expect(::Worker.find(worker.id).status).not_to eq("revoked")
    end
  end

  describe "data-loss protection in delete_volume is unchanged at replay" do
    let(:caller_user) { user_with("system.volumes.delete", floor) }

    it "still refuses an attached volume when the approved call replays" do
      instance = create(:system_node_instance, :running, node: node)
      volume = create(:system_provider_volume, :attached, account: account, node_instance: instance)
      result = run({ action: "system_delete_volume", volume_id: volume.id }, user: caller_user)

      expect(result.dig(:data, :pending)).to be(true)
      replayed = approve!(result).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:error]).to match(/attached/i)
      expect(::System::ProviderVolume.where(id: volume.id)).to exist
    end
  end

  describe "deliberately untouched (held by operator decision)" do
    HELD = {
      "system_upgrade_boot_image" => Ai::Tools::SystemFleetTool,
      "system_drain_instance" => Ai::Tools::SystemFleetTool,
      "system_recycle_pool" => Ai::Tools::SystemFleetTool,
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
