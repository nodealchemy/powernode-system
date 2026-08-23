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

  # A node with NO running instance has no apply target, and the sensor must
  # not emit drift nothing can act on.
  #
  # This exclusion and DecisionEngine#dispatch_reconcile_task are a MIRRORED
  # pair — the same read-side/engine split that APPLY_COMMAND documents below.
  # The applier resolves its target as
  #   payload["instance_id"] || Array(payload["instance_ids"]).first
  # and returns { applied: false, reason: "instance not found" } when that
  # comes back empty (it find_by(id:)s WITHOUT a status filter, so the
  # sensor's NodeInstance.running scope is the only gate on what statuses can
  # ever reach it). An emitted-but-unremediable signal mints a permanent
  # ineffective RemediationOutcome, which is what the F3-11 streak reads as a
  # stuck remediation. Whoever moves either side must move both.
  #
  # This is a re-route, not a coverage deletion: "assignment exists but
  # nothing is running on the node" is a LIVENESS condition owned elsewhere —
  # InstanceStatusSensor (system.instance_silent, :high for an instance that
  # never heartbeat), InstancePoolService's warming-timeout reaper, and
  # DecisionEngine#reap_presumed_dead!. And the sensor holds no state across
  # ticks (FleetAutonomyService#collect_signals builds a fresh sensor each
  # 60s pass and #signal only constructs an unsaved Fleet::Signal), so an
  # assignment skipped today re-enters the candidate set the moment a first
  # instance reaches `running`.
  describe "assignments whose node has no running instance" do
    let(:dead_node) { create(:system_node, account: account, node_template: template) }

    def stale_assignment_on!(target_node)
      create(:system_node_module_assignment, node: target_node).tap do |a|
        a.update_columns(updated_at: 10.minutes.ago)
      end
    end

    # terminated/error are the uncontroversial half. `stopped` and `starting`
    # are the judgment call — a node that may well come back — so they are
    # pinned explicitly: this example fails if someone later widens the
    # `running` scope, which would silently un-gate EMISSION too (the scope is
    # the emission gate and the targeting gate at once).
    it "does not signal when no instance on the node is running" do
      create(:system_node_instance, node: dead_node, status: "terminated")
      create(:system_node_instance, node: dead_node, status: "error")
      create(:system_node_instance, node: dead_node, status: "stopped")
      create(:system_node_instance, node: dead_node, status: "starting")
      dead_assignment = stale_assignment_on!(dead_node)

      signals = sensor.sense

      expect(signals.map { |s| s.payload["assignment_id"] }).not_to include(dead_assignment.id)
      expect(signals.map { |s| s.payload["node_id"] }).not_to include(dead_node.id)
    end

    it "does not signal when the node has no instance rows at all" do
      dead_assignment = stale_assignment_on!(dead_node)

      expect(sensor.sense.map { |s| s.payload["assignment_id"] }).not_to include(dead_assignment.id)
    end

    # The positive half is what proves this is a FILTER and not a mute: a
    # guard that skipped unconditionally would satisfy the two examples above.
    it "still signals for an otherwise-identical assignment whose node has a running instance" do
      create(:system_node_instance, node: dead_node, status: "terminated")
      stale_assignment_on!(dead_node)
      live_assignment = stale_assignment_on!(node)

      signals = sensor.sense

      expect(signals.size).to eq(1)
      expect(signals.first.payload["assignment_id"]).to eq(live_assignment.id)
      expect(signals.first.payload["instance_ids"]).to eq([ running_instance.id ])
    end

    # The skip is a per-tick filter, NOT a suppression that persists. The
    # sensor holds no state (a fresh one per tick, and #signal builds an
    # unsaved Fleet::Signal), the fingerprint is derived from the assignment
    # id alone, and the engine's dedup is a cache TTL — so the same assignment
    # must re-enter the candidate set the moment a first instance comes up.
    # The comments on both sides lean on that property; this makes it an
    # oracle rather than prose. Deliberately re-uses the SAME sensor object
    # across both passes, which is the strictest form of the claim.
    it "signals the same assignment once the node's first instance reaches running" do
      create(:system_node_instance, node: dead_node, status: "starting")
      dead_assignment = stale_assignment_on!(dead_node)

      expect(sensor.sense.map { |s| s.payload["assignment_id"] }).not_to include(dead_assignment.id)

      create(:system_node_instance, :running, node: dead_node)

      revived = sensor.sense.find { |s| s.payload["assignment_id"] == dead_assignment.id }
      expect(revived).to be_present
      expect(revived.payload["instance_ids"].size).to eq(1)
    end
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
    # NodeInstance.running pluck per candidate that survives apply-suppression
    # (F3-09) — i.e. the emitted signals PLUS the no-running-instance skips,
    # which is the same set it ran on before that skip existed.
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
