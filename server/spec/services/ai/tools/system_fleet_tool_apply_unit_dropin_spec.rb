# frozen_string_literal: true

require "rails_helper"

# IMP-9951cbf20bb0 — system_apply_unit_dropin: write (or revert) ONE runtime
# systemd drop-in, /run/systemd/system/<unit>.d/zz-operator-<name>.conf, on a
# node through its own agent. Human-only and approval-gated under its own
# category (system.instance.unit_dropin, require_approval, the shape
# system_out_of_band_exec takes); the replay is the generic
# Ai::Executors::DeferredToolCall, so the request-time checks run again, on
# the same code, when a person's approval lands.
#
# ORACLE SHAPE: the rows. Every refusal asserts no task AND no parked
# operation; the approved path asserts exactly one task.
RSpec.describe Ai::Tools::SystemFleetTool, "system_apply_unit_dropin" do
  let(:account)   { create(:account) }
  # system.nodes.read is the tool floor DeferredToolCall re-asks on replay;
  # ai.autonomy.approve lets this person confirm their own request.
  let(:user) do
    create(:user, account: account, permissions: %w[system.instances.control system.nodes.read ai.autonomy.approve])
  end
  let(:node)      { create(:system_node, account: account) }
  let(:instance)  { create(:system_node_instance, :running, node: node, account: account, last_heartbeat_at: Time.current) }
  let(:fence_key) { System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY }
  let(:decoy)     { create(:system_node, account: create(:account)) }
  let!(:module_record) { create(:system_node_module, account: account) }
  let!(:sidekiq)  { create(:system_module_service, node_module: module_record, name: "sidekiq") }
  let!(:rails_svc) { create(:system_module_service, node_module: module_record, name: "rails") }
  let!(:assignment) { create(:system_node_module_assignment, node: node, node_module: module_record) }
  let(:unit)      { System::RestartAfterUpdate.unit_name(module_record.id, "sidekiq") }
  let(:rails_unit) { System::RestartAfterUpdate.unit_name(module_record.id, "rails") }
  let(:directives) { [ { "key" => "CapabilityBoundingSet", "value" => "" }, { "key" => "AmbientCapabilities", "value" => "" } ] }

  before do
    System::Governance::PolicyReconciler.new(account: account).reconcile!
    ::SiteSetting.set(fence_key, decoy.id, setting_type: "string")
  end

  def tool(u = user)
    described_class.new(account: account, user: u)
  end

  def apply!(t = tool, **rest)
    t.execute(params: { action: "system_apply_unit_dropin", instance_id: instance.id, unit: unit,
                        name: "zero-caps", directives: directives }.merge(rest))
  end

  def dropin_tasks
    System::Task.where(command: System::UnitDropinService::COMMAND)
  end

  def parked
    Ai::DeferredOperation.where(account: account, action_category: System::UnitDropinService::ACTION_CATEGORY)
  end

  def workflow = Ai::Autonomy::ApprovalWorkflowService.new(account: account)

  def parked_after(response)
    expect(response[:data]).to include(pending: true, requires_human_session: true), response.inspect
    Ai::DeferredOperation.find(response[:data][:deferred_operation_id])
  end

  def approve_in_own_session!(deferred, as: user)
    expect(workflow.approve(request: deferred.approval_request, approver: as,
                            origin: Ai::ApprovalDecision::REST_SESSION)).to be(true)
    deferred.reload
  end

  def expect_refused(response, message)
    expect(response[:success]).to be(false)
    expect(response[:error]).to match(message)
    expect(dropin_tasks).to be_empty
    expect(parked).to be_empty
  end

  describe "the declaration" do
    let(:declaration) { described_class.declared_action("system_apply_unit_dropin") }

    it "is mutating, destructive and human-only" do
      expect(declaration).to include(mutating: true, destructive: true, human_only: true)
    end

    it "is gated under its own require_approval category on the generic replay executor" do
      expect(declaration[:action_category]).to eq("system.instance.unit_dropin")
      expect(declaration[:action_category]).to eq(System::UnitDropinService::ACTION_CATEGORY)
      expect(System::Governance::PolicyDeclarations::UNIT_DROPIN_POLICIES)
        .to eq("system.instance.unit_dropin" => "require_approval")
      expect(System::Governance::PolicyDeclarations.owner_of("system.instance.unit_dropin")).to be_nil
      expect(declaration[:executor_class]).to eq("Ai::Executors::DeferredToolCall")
    end

    it "is registered for the Autonomy panel and the policy row is reconciled at scope global" do
      expect(::Ai::InterventionPolicy.registered_categories).to include("system.instance.unit_dropin")
      policy = ::Ai::InterventionPolicy.find_by(account: account, action_category: "system.instance.unit_dropin")
      expect(policy).to have_attributes(scope: "global", ai_agent_id: nil, policy: "require_approval")
    end

    it "is not reported as an unowned category" do
      subjects = ::System::Fleet::Sensors::GovernanceGapSensor.new(account: account).sense.map { |s| s.payload["subject"] }
      expect(subjects).not_to include("system.instance.unit_dropin")
    end

    it "takes system.instances.control and is registered in the tool catalog" do
      expect(described_class::ACTION_PERMISSIONS["system_apply_unit_dropin"]).to eq("system.instances.control")
      expect(::Ai::Tools::PlatformApiToolRegistry.all_tools["system_apply_unit_dropin"]).to eq("Ai::Tools::SystemFleetTool")
    end

    it "requires instance_id, unit and name, and says the restart is system_restart_unit's" do
      definition = described_class.action_definitions.fetch("system_apply_unit_dropin")
      expect(definition[:parameters].slice(:instance_id, :unit, :name).values.map { |p| p[:required] }).to all(be(true))
      expect(definition[:parameters][:directives][:required]).to be(false)
      expect(definition[:parameters][:revert][:required]).to be(false)
      expect(definition[:description]).to include("system_restart_unit")
    end
  end

  describe "the gate" do
    it "parks a human-only approval and creates no task" do
      deferred = parked_after(apply!)

      expect(dropin_tasks).to be_empty
      expect(deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
      expect(deferred.approval_request.requires_human_session?).to be(true)
      expect(deferred.description).to include(unit).and include(instance.name).and include("zero-caps")
    end

    it "still parks under an auto_approve policy (human_only overrides it) and creates no task" do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )

      parked_after(apply!)
      expect(dropin_tasks).to be_empty
    end

    it "creates exactly ONE unit.dropin task when a person approves in their own session" do
      deferred = parked_after(apply!)

      approve_in_own_session!(deferred)

      task = dropin_tasks.sole
      expect(task.operable).to eq(instance)
      expect(task.status).to eq("pending")
      expect(task.initiated_by).to eq(user)
      expect(task.options).to include("unit" => unit, "name" => "zero-caps", "revert" => false)
      expect(AuditLog.where(action: System::UnitDropinService::AUDIT_ACTION).count).to eq(1)
    end

    it "creates nothing when the request is approved with no person's decision" do
      deferred = parked_after(apply!)
      deferred.approval_request.update_columns(status: "approved", completed_at: Time.current)
      deferred.execute_now!

      expect(dropin_tasks).to be_empty
    end

    it "queues a revert through the same gate" do
      deferred = parked_after(apply!(directives: nil, revert: true))
      approve_in_own_session!(deferred)

      expect(dropin_tasks.sole.options).to include("revert" => true, "directives" => [])
    end
  end

  describe "refusals before parking" do
    it "refuses each disallowed directive" do
      [
        %w[ExecStart /bin/sh], %w[ExecStartPre /bin/true], %w[ExecStop /bin/true], %w[ExecReload /bin/true],
        %w[ExecCondition /bin/true], %w[User root], %w[Group root], %w[DynamicUser no],
        %w[NoNewPrivileges false], %w[EnvironmentFile /persist/env], %w[PermissionsStartOnly true]
      ].each do |key, value|
        expect_refused(apply!(directives: [ { "key" => key, "value" => value } ]), /#{key}/)
      end
    end

    it "refuses a ReadWritePaths path outside the allowed roots and one using .." do
      expect_refused(apply!(directives: [ { "key" => "ReadWritePaths", "value" => "/etc" } ]), /ReadWritePaths/)
      expect_refused(apply!(directives: [ { "key" => "ReadWritePaths", "value" => "/persist/../etc" } ]), /ReadWritePaths/)
    end

    it "refuses Environment= outright, benign or not" do
      %w[LOG_LEVEL=debug LD_PRELOAD=/persist/x/evil.so].each do |value|
        expect_refused(apply!(directives: [ { "key" => "Environment", "value" => value } ]),
                       /Environment= is not settable through this verb/)
      end
    end

    it "refuses a capability the unit's manifest does not grant, and a trust path" do
      expect_refused(apply!(directives: [ { "key" => "AmbientCapabilities", "value" => "CAP_SYS_ADMIN" } ]), /CAP_SYS_ADMIN/)
      expect_refused(apply!(directives: [ { "key" => "ReadWritePaths", "value" => "/persist/var/lib/powernode/pki" } ]),
                     /ReadWritePaths/)
    end

    it "refuses newline, CR, control-character, backslash and section-header injection in keys and values" do
      [
        { "key" => "MemoryMax", "value" => "1G\nExecStart=/bin/sh" },
        { "key" => "MemoryMax", "value" => "1G\r" },
        { "key" => "MemoryMax", "value" => "1G\u0000" },
        { "key" => "Environment", "value" => "A=b\\" },
        { "key" => "Environment", "value" => "A=[Service]" },
        { "key" => "MemoryMax\nExecStart", "value" => "/bin/sh" },
        { "key" => "[Service]", "value" => "" }
      ].each do |entry|
        expect_refused(apply!(directives: [ entry ]), /./)
      end
    end

    it "refuses an invalid name" do
      expect_refused(apply!(name: "../../etc/passwd"), /name/)
      expect_refused(apply!(name: "Zero_Caps"), /name/)
    end

    it "refuses the unit refusals shared with system_restart_unit" do
      expect_refused(apply!(unit: "powernode-agent.service"), /agent.*out-of-band/i)
      expect_refused(apply!(unit: "sshd.service"), /powernode-\*/)
      expect_refused(apply!(unit: System::RestartAfterUpdate.unit_name(SecureRandom.uuid, "sidekiq")), /not composed/)

      ::SiteSetting.set(fence_key, node.id, setting_type: "string")
      expect_refused(apply!, /INV-1|self-management/i)
    end

    it "fails closed on a critical service while the fence is unconfigured" do
      ::SiteSetting.where(key: fence_key).delete_all
      expect_refused(apply!(unit: rails_unit), /self_hosting_node_id/)
    end

    it "refuses an instance whose agent went silent" do
      instance.update_columns(last_heartbeat_at: 1.hour.ago)
      expect_refused(apply!, /went silent/)
    end

    it "refuses an unknown instance" do
      expect_refused(apply!(instance_id: SecureRandom.uuid), /Couldn't find System::NodeInstance/)
    end
  end

  describe "an instance principal" do
    def instance_tool
      described_class.new(account: account, user: nil).tap do |x|
        x.instance_authorized = true
        x.node_instance = instance
      end
    end

    it "is denied by the overlay, whatever it has granted itself" do
      expect(::Mcp::Principal.destructive_tool?("platform.system_apply_unit_dropin")).to be true
      expect(::Mcp::Principal.destructive_tool?("system_apply_unit_dropin")).to be true
    end

    it "is refused at the door before any gate work" do
      expect { apply!(instance_tool) }.to raise_error(Mcp::ProtocolService::PermissionDeniedError, /destroy-shaped/)
      expect(dropin_tasks).to be_empty
      expect(parked).to be_empty
    end

    it "is refused by the gate context and the arm themselves, independent of the overlay" do
      params = { action: "system_apply_unit_dropin", instance_id: instance.id, unit: unit, name: "x", directives: directives }
      t = instance_tool

      expect { t.send(:apply_unit_dropin_gate_context, params) }
        .to raise_error(Ai::Tools::BaseTool::CallerFacingError, /instance principal/)
      expect(t.send(:apply_unit_dropin, params)).to include(success: false)
      expect(dropin_tasks).to be_empty
    end
  end

  # F5: the call arm runs only on a PERSON's own-session approved replay, not
  # on any approved replay — defence in depth beneath BaseTool#execute's
  # human_only branch, for a caller that reaches #call directly.
  describe "an approved replay no person confirmed, reaching #call directly" do
    it "is gate-routed only and creates nothing" do
      deferred = parked_after(apply!)
      deferred.approval_request.update_columns(status: "approved", completed_at: Time.current)
      deferred.update_columns(status: "executing")
      t = tool
      t.replaying_operation = deferred.reload

      result = t.send(:call, { action: "system_apply_unit_dropin", instance_id: instance.id, unit: unit,
                               name: "zero-caps", directives: directives })

      expect(result[:success]).to be(false)
      expect(dropin_tasks).to be_empty
    end
  end

  describe "a bare #call (no approved replay)" do
    it "is gate-routed only and creates nothing" do
      result = tool.send(:call, { action: "system_apply_unit_dropin", instance_id: instance.id, unit: unit,
                                  name: "zero-caps", directives: directives })

      expect(result[:success]).to be(false)
      expect(dropin_tasks).to be_empty
    end
  end

  describe "replay-time re-validation" do
    it "creates no task when the unit stopped being composed while the request was parked" do
      deferred = parked_after(apply!)
      assignment.destroy!

      approve_in_own_session!(deferred)

      expect(dropin_tasks).to be_empty
      expect(deferred.result.to_s).to match(/not composed on this instance/)
    end

    it "creates no task when the node became the control plane's own host while parked" do
      deferred = parked_after(apply!)
      ::SiteSetting.set(fence_key, node.id, setting_type: "string")

      approve_in_own_session!(deferred)

      expect(dropin_tasks).to be_empty
      expect(deferred.result.to_s).to match(/INV-1|self-management/i)
    end
  end
end
