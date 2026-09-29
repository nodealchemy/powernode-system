# frozen_string_literal: true

require "rails_helper"

# IMP-88e82d59b7f2 — System::UnitRestartService, the ONE author of the request-
# time and replay-time checks behind system_restart_unit, and of the restart
# task itself. The agent's LifecycleHandler (validateUnit) is the SECOND layer:
# it refuses a unit its own node did not materialise, but it cannot see the
# control plane's self-hosting fence, the reason, or the agent-unit rule.
#
# ORACLE SHAPE: every refusal asserts NO task row, never only the message; each
# is paired with a permitted opposite so "refuse everything" cannot pass.
RSpec.describe System::UnitRestartService do
  let(:account)   { create(:account) }
  let(:node)      { create(:system_node, account: account) }
  let(:instance)  { create(:system_node_instance, :running, node: node, account: account, last_heartbeat_at: Time.current) }
  let(:user)      { create(:user, account: account) }
  let(:fence_key) { System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY }
  # A decoy self-hosting node: the fence is CONFIGURED and points elsewhere.
  let(:decoy)     { create(:system_node, account: create(:account)) }

  def compose!(inst, *names)
    mod = create(:system_node_module, account: account)
    svcs = names.map { |n| create(:system_module_service, node_module: mod, name: n) }
    create(:system_node_module_assignment, node: inst.node, node_module: mod)
    svcs.map { |s| System::RestartAfterUpdate.unit_name(mod.id, s.name) }
  end

  def restart_tasks
    System::Task.where(command: "restart")
  end

  before { ::SiteSetting.set(fence_key, decoy.id, setting_type: "string") }

  describe ".composed_units" do
    it "lists the units of the modules attached to the instance's node, named as the agent names them" do
      units = compose!(instance, "sidekiq", "worker-web")
      other = create(:system_node_instance, :running, account: account)
      foreign = compose!(other, "sidekiq")

      composed = described_class.composed_units(instance)

      expect(composed.map(&:unit)).to match_array(units)
      expect(composed.map(&:service)).to match_array(%w[sidekiq worker-web])
      expect(composed.map(&:unit)).not_to include(*foreign)
    end

    it "resolves a dependant child (parent_module_id, no assignment row), the second pathway attached_modules honours" do
      parent = create(:system_node_module, account: account)
      child = create(:system_node_module, account: account, node: node, parent_module: parent, enabled: true)
      create(:system_module_service, node_module: child, name: "sidekiq")
      expect(System::NodeModuleAssignment.where(node_module_id: child.id)).to be_empty

      expect(described_class.composed_units(instance).map(&:unit))
        .to eq([ System::RestartAfterUpdate.unit_name(child.id, "sidekiq") ])
    end

    it "omits a module whose assignment is disabled, and is empty for an instance with no node" do
      mod = create(:system_node_module, account: account)
      create(:system_module_service, node_module: mod, name: "sidekiq")
      create(:system_node_module_assignment, node: node, node_module: mod, enabled: false)

      expect(described_class.composed_units(instance)).to be_empty
      allow(instance).to receive(:node).and_return(nil)
      expect(described_class.composed_units(instance)).to be_empty
    end
  end

  describe "#refusal" do
    subject(:service) { described_class.new }

    let!(:units) { compose!(instance, "sidekiq", "rails", "postgres", "node-exporter") }
    let(:sidekiq) { units[0] }
    let(:rails)   { units[1] }
    let(:postgres) { units[2] }
    let(:node_exporter) { units[3] }

    def refusal(unit, reason: "post-deploy bounce")
      service.refusal(instance: instance, unit: unit, reason: reason)
    end

    it "permits a composed unit with a reason" do
      expect(refusal(sidekiq)).to be_nil
    end

    it "requires a non-blank, bounded reason" do
      expect(refusal(sidekiq, reason: nil)).to match(/reason is required/i)
      expect(refusal(sidekiq, reason: "   ")).to match(/reason is required/i)
      expect(refusal(sidekiq, reason: "x" * (described_class::REASON_MAX_LENGTH + 1))).to match(/at most #{described_class::REASON_MAX_LENGTH}/)
      expect(refusal(sidekiq, reason: "x" * described_class::REASON_MAX_LENGTH)).to be_nil
    end

    it "refuses a blank unit" do
      expect(refusal("")).to match(/unit is required/i)
      expect(refusal(nil)).to match(/unit is required/i)
    end

    it "refuses the agent's own unit and its variants, saying agent restarts stay out-of-band" do
      %w[powernode-agent.service powernode-agent@x.service powernode-agent-updater.service POWERNODE-AGENT.service].each do |unit|
        expect(refusal(unit)).to match(/agent.*out-of-band/i), "expected #{unit} refused"
      end
    end

    it "refuses a unit outside the managed powernode-* namespace" do
      %w[sshd.service nginx.service systemd-journald.service].each do |unit|
        expect(refusal(unit)).to match(/powernode-\*/), "expected #{unit} refused"
      end
    end

    it "refuses a malformed name that only looks managed" do
      [ "powernode-x.service; reboot", "powernode-../etc.service", "powernode-x", "powernode-a b.service", "powernode-x.timer" ].each do |unit|
        expect(refusal(unit)).to match(/not a well-formed managed unit name/), "expected #{unit.inspect} refused as malformed"
      end
    end

    it "refuses a managed unit that is not composed on this instance (unknown and foreign)" do
      unknown = System::RestartAfterUpdate.unit_name(SecureRandom.uuid, "sidekiq")
      other = create(:system_node_instance, :running, account: account)
      foreign = compose!(other, "sidekiq").first

      expect(refusal(unknown)).to match(/not composed on this instance/i)
      expect(refusal(foreign)).to match(/not composed on this instance/i)
    end

    context "when the control plane's own hosting node is the target (INV-1)" do
      before { ::SiteSetting.set(fence_key, node.id, setting_type: "string") }

      # INV-1 is node-scoped, not service-scoped: the node is refused whole.
      it "refuses EVERY composed unit, critical or not" do
        [ rails, postgres, sidekiq, node_exporter ].each do |unit|
          expect(refusal(unit)).to match(/INV-1|self-management/i), "expected #{unit} refused"
        end
      end
    end

    context "when the fence is unconfigured" do
      before { ::SiteSetting.where(key: fence_key).delete_all }

      # Unset means "cannot tell whether this is the control plane's node", so
      # the services the control plane runs on are refused. Names are the
      # shipped manifests' SERVICE names, not their module names.
      it "fails closed for every critical service, naming the setting" do
        names = %w[rails rails-setup postgres pg-replica redis vault traefik restore-dynamic sidekiq worker-web caddy]
        units = compose!(instance, *names)

        units.each do |unit|
          expect(refusal(unit)).to match(/self_hosting_node_id/), "expected #{unit} refused"
        end
      end

      it "permits a service that is not one the control plane runs on" do
        expect(refusal(node_exporter)).to be_nil
      end
    end

    it "permits rails on a node that is not the self-hosting one" do
      expect(refusal(rails)).to be_nil
    end

    it "refuses an instance that is not running" do
      instance.update_columns(status: "stopped")
      expect(refusal(sidekiq)).to match(/stopped/)
    end

    it "refuses a running instance whose agent went silent or never reported, and permits it once it reports" do
      instance.update_columns(last_heartbeat_at: 1.hour.ago)
      expect(refusal(sidekiq)).to match(/went silent/)

      instance.update_columns(last_heartbeat_at: nil)
      expect(refusal(sidekiq)).to match(/never reported/)

      instance.update_columns(last_heartbeat_at: Time.current)
      expect(refusal(sidekiq)).to be_nil
    end

    it "refuses an instance whose status no agent will pull a task under" do
      instance.update_columns(status: "error")
      expect(refusal(sidekiq)).to be_present
    end
  end

  describe "#restart!" do
    it "creates exactly one restart task carrying the unit scope, and audits the reason" do
      unit = compose!(instance, "sidekiq").first

      task = nil
      expect { task = described_class.new.restart!(instance: instance, unit: unit, reason: "  bounce after config  ", initiated_by: user) }
        .to change { restart_tasks.count }.by(1)

      expect(task.operable).to eq(instance)
      expect(task.status).to eq("pending")
      expect(task.initiated_by).to eq(user)
      expect(task.options).to include("scope" => "unit", "unit" => unit, "reason" => "bounce after config")
      expect(task.description).to include("bounce after config")

      audit = AuditLog.find_by!(action: described_class::AUDIT_ACTION, resource_id: instance.id.to_s)
      expect(audit.account_id).to eq(account.id)
      expect(audit.user_id).to eq(user.id)
      expect(audit.metadata).to include("reason" => "bounce after config", "unit" => unit, "task_id" => task.id)
    end

    it "raises Refused and creates nothing for what #refusal refuses" do
      compose!(instance, "sidekiq")

      expect { described_class.new.restart!(instance: instance, unit: "powernode-agent.service", reason: "x", initiated_by: user) }
        .to raise_error(described_class::Refused, /out-of-band/)
      expect(restart_tasks).to be_empty
      expect(AuditLog.where(action: described_class::AUDIT_ACTION)).to be_empty
    end

    it "creates no task when the audit row cannot be written" do
      unit = compose!(instance, "sidekiq").first
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

      expect { described_class.new.restart!(instance: instance, unit: unit, reason: "x", initiated_by: user) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(restart_tasks).to be_empty
    end
  end
end
