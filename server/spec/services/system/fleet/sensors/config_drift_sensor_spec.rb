# frozen_string_literal: true

require "rails_helper"

# Audit F3-09 — ConfigDriftSensor's payload carried node_id/module_id/
# assignment_id but no instance reference, while the decision engine's
# config_drift binding and reconcile-task dispatch resolve the remediation
# target from the payload's instance ids. Every config-drift skill
# invocation ran with instance_id: nil and failed.
RSpec.describe System::Fleet::Sensors::ConfigDriftSensor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let!(:running_instance) { create(:system_node_instance, :running, node: node) }

  let(:sensor) { described_class.new(account: account) }

  # The sensor's staleness window is 5 minutes from the assignment's
  # updated_at — update_columns avoids touching the timestamp back to now.
  def stale_assignment!
    create(:system_node_module_assignment, node: node).tap do |a|
      a.update_columns(updated_at: 10.minutes.ago)
    end
  end

  it "emits config_drift carrying the node's running instance ids" do
    assignment = stale_assignment!

    signals = sensor.sense

    expect(signals.size).to eq(1)
    signal = signals.first
    expect(signal.kind).to eq("system.config_drift")
    expect(signal.payload["assignment_id"]).to eq(assignment.id)
    expect(signal.payload["instance_ids"]).to eq([ running_instance.id ])
  end

  it "excludes non-running instances from the payload" do
    create(:system_node_instance, node: node, status: "stopped")
    stale_assignment!

    expect(sensor.sense.first.payload["instance_ids"]).to eq([ running_instance.id ])
  end

  # IMP-a99067b836bf — the "already applied?" guard probed
  # System::Task(operable_type: "System::Node", command LIKE "system.attach%").
  # No such task can exist: `system.attach` appears nowhere else in the repo
  # and System::Task::COMMANDS has no entry with that prefix. So `last_apply`
  # was structurally always nil, the guard never fired, and every assignment
  # older than STALE_THRESHOLD re-emitted system.config_drift on every 60s
  # tick forever (~500 signals/tick on ops-hub, growing by 4 per new node).
  #
  # What the decision engine actually dispatches for system.config_drift is
  # `command: "apply_config"` on a System::NodeInstance
  # (DecisionEngine::REMEDIATION_APPLIERS + #dispatch_reconcile_task), so the
  # probe has to look there — and it has to keep SIGNALLING for an apply that
  # predates the change, which is the half a suppression bug would silently
  # break.
  describe "suppression once the change has been applied" do
    # completed_at is passed independently of status ON PURPOSE: System::Task
    # stamps it on fail!/abort!/cancel! as well as complete!
    # (task.rb:127/137/147/157). So an apply_config that ERRORED still carries a
    # timestamp, and a probe filtering on completed_at alone would read it as
    # "applied" and go quiet — the over-suppression failure mode. A fixture that
    # nils completed_at for those statuses cannot see that, and silently makes
    # the status clause untestable.
    # created_at is set explicitly, never left to the factory: the pre-fix probe
    # read created_at and the fixed one reads completed_at, so the two columns
    # must disagree for any example to tell them apart. Leaving created_at at
    # "now" made that discrimination accidental — it would evaporate the moment
    # someone backdated the row.
    def apply_config_task!(instance:, completed_at:, status: "complete",
                           created_at: Time.current, account: self.account)
      create(:system_task,
             account: account,
             operable: instance,
             command: "apply_config",
             status: status,
             progress: status == "complete" ? 100 : 0,
             created_at: created_at,
             completed_at: completed_at)
    end

    it "goes silent when an apply_config completed AFTER the assignment changed" do
      stale_assignment!
      apply_config_task!(instance: running_instance, completed_at: 2.minutes.ago)

      expect(sensor.sense).to be_empty
    end

    it "still signals when the apply_config completed BEFORE the assignment changed" do
      applied_at = 30.minutes.ago
      stale_assignment!
      # created_at "now" is deliberately on the SUPPRESSING side of the
      # assignment's 10-minutes-ago change while completed_at is not, so this
      # example fails against a probe that reads created_at.
      apply_config_task!(instance: running_instance, completed_at: applied_at, created_at: Time.current)

      signals = sensor.sense

      expect(signals.size).to eq(1)
      # Not merely "a signal fired": the probe must have FOUND the task. Every
      # one of the 98 live config_drift events carried last_apply_at: null,
      # which is the observable signature of the dead probe.
      expect(signals.first.payload["last_apply_at"]).to eq(applied_at.iso8601)
    end

    it "suppresses on the LATEST apply, not the earliest" do
      stale_assignment!
      apply_config_task!(instance: running_instance, completed_at: 30.minutes.ago)
      apply_config_task!(instance: running_instance, completed_at: 2.minutes.ago)

      expect(sensor.sense).to be_empty
    end

    it "still signals while the apply_config is only in flight" do
      stale_assignment!
      # A non-nil completed_at on a still-running task is reachable — the
      # internal task-report endpoint sets the column independently of status.
      # Nilling it here instead would make this example pass against a probe
      # with no status filter at all, i.e. name the status clause without
      # testing it.
      apply_config_task!(instance: running_instance, completed_at: 2.minutes.ago, status: "running")

      signals = sensor.sense

      expect(signals.size).to eq(1)
      expect(signals.first.payload["last_apply_at"]).to be_nil
    end

    it "ignores an apply stamped in the future" do
      stale_assignment!
      apply_config_task!(instance: running_instance, completed_at: 1.hour.from_now)

      # A future stamp would otherwise outrank every subsequent assignment
      # change and silence this node forever.
      expect(sensor.sense.size).to eq(1)
    end

    %w[failed aborted cancelled].each do |status|
      it "still signals when the most recent apply_config #{status} (completed_at is stamped anyway)" do
        stale_assignment!
        apply_config_task!(instance: running_instance, completed_at: 2.minutes.ago, status: status)

        signals = sensor.sense
        expect(signals.size).to eq(1)
        expect(signals.first.payload["last_apply_at"]).to be_nil
      end
    end

    it "does not let one node's apply_config silence another node's drift" do
      other_node = create(:system_node, account: account, node_template: template)
      other_instance = create(:system_node_instance, :running, node: other_node)
      create(:system_node_module_assignment, node: other_node).update_columns(updated_at: 10.minutes.ago)
      stale_assignment!

      apply_config_task!(instance: other_instance, completed_at: 2.minutes.ago)

      signals = sensor.sense
      expect(signals.size).to eq(1)
      expect(signals.first.payload["node_id"]).to eq(node.id)
    end

    it "does not let another account's task silence our drift" do
      stale_assignment!
      apply_config_task!(instance: running_instance, completed_at: 2.minutes.ago,
                         account: create(:account))

      signals = sensor.sense
      expect(signals.size).to eq(1)
      # Distinguishes "excluded from the probe" from "found, but signalled for
      # some other reason".
      expect(signals.first.payload["last_apply_at"]).to be_nil
    end

    it "applies one node's last apply to every assignment on that node" do
      old_assignment = create(:system_node_module_assignment, node: node)
      old_assignment.update_columns(updated_at: 30.minutes.ago)
      recent_assignment = stale_assignment! # 10 minutes ago

      apply_config_task!(instance: running_instance, completed_at: 20.minutes.ago)

      signals = sensor.sense

      # The grouped hash is consulted once per assignment — which is the whole
      # reason it is keyed by node rather than computed per row.
      expect(signals.map { |s| s.payload["assignment_id"] }).to eq([ recent_assignment.id ])
      expect(signals.map { |s| s.payload["assignment_id"] }).not_to include(old_assignment.id)
    end

    it "does not let a non-apply_config task silence drift" do
      stale_assignment!
      create(:system_task, account: account, operable: running_instance,
             command: "sync_modules", status: "complete", progress: 100,
             completed_at: 2.minutes.ago)

      expect(sensor.sense.size).to eq(1)
    end

    # The dead probe ran one system_tasks query per assignment inside find_each;
    # ops-hub has ~450 assignments. Repointing it must not keep that shape.
    # Scope note: this counts system_tasks queries only. #sense also runs one
    # NodeInstance.running pluck per EMITTED signal (F3-09) — pre-existing, and
    # untouched here, though suppression now keeps it off the silenced majority.
    it "resolves the last apply for every node in a single tasks query" do
      3.times do
        n = create(:system_node, account: account, node_template: template)
        create(:system_node_module_assignment, node: n).update_columns(updated_at: 10.minutes.ago)
      end

      queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries += 1 if payload[:sql].to_s.include?('FROM "system_tasks"') && !payload[:cached]
      end
      begin
        sensor.sense
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(queries).to eq(1)
    end

    # APPLY_COMMAND/APPLIED_STATUS deliberately MIRROR the decision engine
    # rather than referencing it — sensors are read-side and must not depend on
    # the engine that consumes them. The mirror still needs a drift guard, or
    # the probe goes structurally dead again the day the remediation is
    # renamed, exactly as it did the first time.
    it "mirrors what the decision engine actually dispatches for config_drift" do
      applier = System::Fleet::DecisionEngine::REMEDIATION_APPLIERS.fetch("system.config_drift")

      expect(described_class::APPLY_COMMAND).to eq(applier[:command])
      # The original defect in one assertion: the probed command was not in the
      # allowlist, so no task could ever carry it.
      expect(System::Task::COMMANDS).to include(described_class::APPLY_COMMAND)
      expect(System::Task::STATUSES).to include(described_class::APPLIED_STATUS)
    end
  end
end
