# frozen_string_literal: true

require "rails_helper"

# IMP-848c7e953e2d — a remediation that DECLARES it did not converge must not be
# scored by fingerprint absence (nor by fingerprint presence).
#
# THE DEFECT THIS PINS. Two appliers in DecisionEngine return "I applied what I
# could, but the fleet cannot converge until this node reboots":
#
#   apply_template_closure_drift's pivot arm — the assignment rows are created,
#     but a pivot-booted instance composes its module union at boot, so nothing
#     is mounted now. TemplateApplyService#apply! creates precisely the rows
#     TemplateClosureDriftSensor subtracts (both sides build the expansion from
#     `TemplateExpansionService.new(template_modules: template.template_modules)`
#     and diff it against `node.node_module_assignments`), so after one apply
#     the sensor's difference is empty BY CONSTRUCTION and the fingerprint is
#     gone from every later sense pass — absence that carries no information.
#
#     THIS ARM IS DEFENCE IN DEPTH, NOT A LIVE DEFECT. In production the lane
#     never reaches the validate arc: DecisionEngine#force_policy_for forces
#     require_approval for system.template_closure_drift whenever the payload's
#     requires_approval is set, and it is always set (the sensor filters by
#     TemplateApprovalPolicy::LIVE_INSTANCE_SCOPE and the policy counts nodes
#     over the same scope, so a firing sensor implies count >= 1). A forced
#     require_approval decides :pending, and record_proceeded! records only
#     :proceed — no row is minted, so nothing was ever scored EFFECTIVE. The
#     example below reaches the arm only by hand-writing requires_approval
#     false into a payload the sensor cannot emit; it pins the applier's
#     contract for the day the gate changes, and is labelled as such.
#
#   reboot_pending_escalation — the agent already FAILED the last reconcile of
#     this command with "reboot_pending", so the engine deliberately does not
#     re-dispatch. Here the drift fingerprint is still LIVE on every later pass,
#     so the same validator scores it INEFFECTIVE, three of those trip
#     STUCK_STREAK_THRESHOLD, and a lane that declined correctly manufactures a
#     false fleet.remediation_stuck escalation.
#
# Both verdicts are measurement errors in opposite directions, and both come
# from the same missing fact: the applier knows convergence was deferred and had
# no way to say so. `requires_reprovision` was that attempt and it had ZERO
# readers — it recorded the skip where nothing looked.
#
# ORACLE: the RemediationOutcome ROW's status, and — for the live half — the
# escalation the row's disposition feeds. Asserting the applier's RETURN VALUE
# is what let this survive: decision_engine_spec has asserted the old
# requires_reprovision flag's value for as long as it existed, green the whole
# time, because the defect was never in what the applier said. (This diff does
# change those return hashes: the key is renamed in all three, and the
# clobbering `requires_reprovision: false` is dropped from the non-pivot merge.
# Those renames are pinned in decision_engine_spec; they are not the oracle.)
RSpec.describe "deferred-convergence remediation scoring", type: :service do
  let(:account)   { create(:account) }
  let(:agent)     { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)   { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)    { System::Fleet::DecisionEngine.new(autonomy_service: service) }
  let(:validator) { System::Fleet::RemediationValidator.new(account: account, agent: agent) }

  let(:platform)  { create(:system_node_platform, account: account) }
  let(:node)      { create(:system_node, account: account, node_template: template) }
  let!(:instance) { create(:system_node_instance, :running, node: node) }
  let(:module_a)  { create(:system_node_module, account: account, name: "closure-a-#{SecureRandom.hex(3)}") }

  # Settle the outcome the validator just minted and score it against a sense
  # pass. Returns the reloaded row.
  def score!(fingerprint, current_signals:)
    outcome = System::Fleet::RemediationOutcome.find_by!(account: account, fingerprint: fingerprint)
    outcome.update!(settle_until: 2.minutes.ago)
    validator.validate_due!(current_signals: current_signals)
    outcome.reload
  end

  describe "the template-closure pivot arm (absence is not evidence)" do
    let(:template) do
      create(:system_node_template, account: account, node_platform: platform,
                                    config: { "boot_mode" => "direct_kernel" })
    end

    let(:signal) do
      System::Fleet::Signal.new(
        kind: "system.template_closure_drift", severity: :medium,
        payload: { "instance_id" => instance.id, "node_id" => node.id, "template_id" => template.id,
                   "missing_module_ids" => [ module_a.id ], "missing_count" => 1,
                   "requires_approval" => false, "_sensor" => "TemplateClosureDriftSensor" },
        fingerprint: "template_closure_drift:#{instance.id}"
      )
    end

    before do
      create(:system_template_module, node_template: template, node_module: module_a)
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.template_closure_apply",
                                     policy: "notify_and_proceed", is_active: true)
    end

    it "scores the outcome INCONCLUSIVE, not effective, when the applier deferred convergence" do
      expect(instance.pivot_boot?).to be(true), "fixture is not on the pivot arm"

      decision = engine.decide(signal)
      expect(decision[:decision]).to eq(:proceed)
      # The applier does its half: the assignment row exists. That is exactly
      # what makes the sensor go quiet, which is why its silence proves nothing.
      expect(System::NodeModuleAssignment.exists?(node: node, node_module: module_a)).to be true
      expect(System::Task.where(account: account, command: "sync_modules", operable: instance)).to be_empty

      validator.record_proceeded!(decisions: [ decision ], signals: [ signal ])

      # The closure sensor is silent by construction on the next pass — the
      # applier created the rows it subtracts. current_signals is empty.
      outcome = score!(signal.fingerprint, current_signals: [])

      expect(outcome.status).to eq("inconclusive")
      # The load-bearing key: validate_due! branches on THIS, not on the reason
      # string. The reason is operator prose and is asserted only for presence.
      expect(outcome.metadata["convergence_deferred"]).to be true
      expect(outcome.metadata["deferred_reason"]).to be_present
    end
  end

  describe "the reboot_pending escalation (presence is not evidence either)" do
    let(:template) { create(:system_node_template, account: account, node_platform: platform) }

    let(:signal) do
      System::Fleet::Signal.new(
        kind: "system.module_drift", severity: :medium,
        payload: { "instance_id" => instance.id, "_sensor" => "ModuleDriftSensor" },
        fingerprint: "module_drift:#{instance.id}"
      )
    end

    before do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.module_assign",
                                     policy: "notify_and_proceed", is_active: true)
      allow_any_instance_of(::System::Ai::Skills::DriftRemediateExecutor).to receive(:execute).and_return(
        { success: true, data: { resolved: true, requires_approval: false, disruption_pct: 5,
                                 planned_actions: { attach: [ "mod-1" ], detach: [], update: [] } } }
      )
      # The agent already refused this exact reconcile: the module's content
      # cannot be materialized live. reboot_pending_escalation fires.
      System::Task.create!(
        account: account, operable: instance, command: "sync_modules", status: "failed",
        error_message: "reconcile did not converge 1 module(s): " \
                       "reconciler:reboot_pending [mod-base-os]: reboot_required=true",
        completed_at: 1.minute.ago
      )
    end

    it "scores the outcome INCONCLUSIVE, not ineffective, and does not feed the stuck streak" do
      decision = engine.decide(signal)
      expect(decision[:decision]).to eq(:proceed)
      expect(decision[:remediation]).to include(applied: false)

      validator.record_proceeded!(decisions: [ decision ], signals: [ signal ])

      # The drift is STILL firing — of course it is, nobody rebooted. Presence
      # here is the expected state of a deferred remediation, not a failure of
      # one.
      outcome = score!(signal.fingerprint, current_signals: [ signal ])

      expect(outcome.status).to eq("inconclusive")
      expect(
        System::Fleet::RemediationOutcome.ineffective_streak(account: account, fingerprint: signal.fingerprint)
      ).to eq(0)
    end

    # THE BRAKE. Holding the row out of the streak removes the ONLY thing that
    # ever told an operator about a node that can be fixed only by a reboot —
    # before this change, three ineffective windows tripped
    # STUCK_STREAK_THRESHOLD into a HIGH fleet.remediation_stuck. Settling
    # `inconclusive` pins that streak at 0, so the escalation has to arrive by
    # another route or the lane goes silent. It arrives through the SAME
    # escalate_stuck_remediation!, keyed on the settled row instead of on a
    # count. The validator's own :proposal exemption states the rule
    # (remediation_validator.rb: pinning the streak at 0 "disables F3-11 as the
    # lane's brake") and names its replacement; this is the assertion that ours
    # exists.
    it "escalates to the operator on the next decide, and mints no further outcome row" do
      first = engine.decide(signal)
      expect(first[:decision]).to eq(:proceed)
      validator.record_proceeded!(decisions: [ first ], signals: [ signal ])
      expect(score!(signal.fingerprint, current_signals: [ signal ]).status).to eq("inconclusive")

      # Stands in for DEDUP_TTL_SECONDS elapsing — #recently_decided? is a
      # Rails.cache read, and without this the second decide short-circuits as a
      # duplicate before reaching any of the logic under test.
      Rails.cache.clear

      second = nil
      expect { second = engine.decide(signal) }
        .to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }.by(1)

      expect(second[:remediation_stuck]).to be true
      expect(second[:convergence_deferred]).to be true
      expect(second[:decision]).not_to eq(:proceed)

      event = System::FleetEvent.where(kind: "fleet.remediation_stuck").order(:created_at).last
      expect(event.severity).to eq("high")
      expect(event.payload["convergence_deferred"]).to be true
      expect(event.payload["fingerprint"]).to eq(signal.fingerprint)

      # And the churn objection: an escalated decision is not :proceed, so
      # record_proceeded! adds nothing on top of the row already settled.
      expect {
        validator.record_proceeded!(decisions: [ second ], signals: [ signal ])
      }.not_to change { System::Fleet::RemediationOutcome.where(account: account).count }
    end

    # The F3-11 sensor-failure guard withholds scoring when the owning sensor
    # CRASHED, because absence is not evidence on a tick the sensor never ran.
    # A deferred outcome does not need that protection and must not inherit its
    # "stay pending" behaviour: absence was never its evidence either way, and
    # leaving it pending would put it back in `due` to be re-examined forever.
    # So the deferred branch runs FIRST, and this pins that ordering — the
    # targeted runs above cannot see it, since score! always passes no failures.
    # THE BLOCK MUST LAPSE. The escalation branch returns before the gate, so a
    # blocked fingerprint can never PROCEED, and only a PROCEEDED decision mints
    # an outcome — nothing this lane does can lift its own block. Unbounded,
    # that is worse than the silence it replaced: the fingerprint is
    # per-INSTANCE, so one reboot-deferred module would take that instance out
    # of autonomous remediation for every future drift, including ordinary ones
    # a live sync fixes. These two examples pin the two ways out.
    it "stops blocking once the deferred row is older than DEFERRED_BLOCK_WINDOW" do
      first = engine.decide(signal)
      validator.record_proceeded!(decisions: [ first ], signals: [ signal ])
      outcome = score!(signal.fingerprint, current_signals: [ signal ])
      expect(outcome.status).to eq("inconclusive")
      Rails.cache.clear

      window = System::Fleet::RemediationOutcome::DEFERRED_BLOCK_WINDOW
      outcome.update!(validated_at: (window + 60).seconds.ago)

      # The agent's refusal is also gone (its failed task is what
      # reboot_pending_escalation reads), i.e. the node was rebooted and the
      # module materialized — so the lane must remediate again, not escalate.
      System::Task.where(account: account, operable: instance, command: "sync_modules").delete_all

      resumed = nil
      expect { resumed = engine.decide(signal) }
        .not_to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }
      expect(resumed[:decision]).to eq(:proceed)
      expect(resumed[:remediation]).to include(applied: true, command: "sync_modules")
    end

    it "stops blocking once a LATER outcome for the same fingerprint actually scored" do
      first = engine.decide(signal)
      validator.record_proceeded!(decisions: [ first ], signals: [ signal ])
      deferred_row = score!(signal.fingerprint, current_signals: [ signal ])
      expect(deferred_row.status).to eq("inconclusive")

      # A later remediation on the same instance that DID converge. Written
      # through the same column the validator writes, and settled AFTER the
      # deferred row, so the newest-settled read has to prefer it.
      System::Fleet::RemediationOutcome.create!(
        account: account, signal_kind: signal.kind, fingerprint: signal.fingerprint,
        status: "effective", acted_at: 1.minute.ago, settle_until: 30.seconds.ago,
        validated_at: deferred_row.validated_at + 1.second
      )

      expect(
        System::Fleet::RemediationOutcome.deferred_convergence?(
          account: account, fingerprint: signal.fingerprint
        )
      ).to be false
    end

    it "settles even when the owning sensor crashed on this tick" do
      decision = engine.decide(signal)
      validator.record_proceeded!(decisions: [ decision ], signals: [ signal ])

      outcome = System::Fleet::RemediationOutcome.find_by!(account: account, fingerprint: signal.fingerprint)
      outcome.update!(settle_until: 2.minutes.ago)
      expect(outcome.metadata["sensor"]).to eq("ModuleDriftSensor")

      validator.validate_due!(current_signals: [], failed_sensors: %w[ModuleDriftSensor])

      expect(outcome.reload.status).to eq("inconclusive")
    end
  end

  # CONTROL. Without this the change could mark every outcome inconclusive and
  # both examples above would still pass — the validate arc would score nothing
  # at all, which is a worse defect than the one being fixed.
  #
  # NOT a claim that the cloud_init arm MEASURES anything. apply! runs on both
  # arms before the pivot split, so this arm's fingerprint is silenced by
  # construction too and its outcome settles 90s later regardless of whether
  # the dispatched sync_modules ever converged. What these two examples pin is
  # only that a NON-DECLARING applier still reaches the scoring branches at
  # all — i.e. that the new branch is keyed on the declaration and not on the
  # signal kind, the arm, or nothing. Whether template_closure_apply should be
  # scorable by its own fingerprint at all is a separate, larger question.
  describe "an applier that does NOT declare a deferral still reaches scoring" do
    let(:template) { create(:system_node_template, account: account, node_platform: platform) }

    let(:signal) do
      System::Fleet::Signal.new(
        kind: "system.template_closure_drift", severity: :medium,
        payload: { "instance_id" => instance.id, "node_id" => node.id, "template_id" => template.id,
                   "missing_module_ids" => [ module_a.id ], "missing_count" => 1,
                   "requires_approval" => false, "_sensor" => "TemplateClosureDriftSensor" },
        fingerprint: "template_closure_drift:#{instance.id}"
      )
    end

    before do
      create(:system_template_module, node_template: template, node_module: module_a)
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.template_closure_apply",
                                     policy: "notify_and_proceed", is_active: true)
    end

    it "reaches the EFFECTIVE branch on absence when the applier did NOT defer (cloud_init arm)" do
      expect(instance.pivot_boot?).to be(false), "fixture is on the pivot arm"

      decision = engine.decide(signal)
      expect(decision[:decision]).to eq(:proceed)
      expect(System::Task.find_by(account: account, command: "sync_modules", operable: instance)).to be_present

      validator.record_proceeded!(decisions: [ decision ], signals: [ signal ])
      outcome = score!(signal.fingerprint, current_signals: [])

      expect(outcome.status).to eq("effective")
    end

    it "reaches the INEFFECTIVE branch on presence when the applier did NOT defer" do
      decision = engine.decide(signal)
      validator.record_proceeded!(decisions: [ decision ], signals: [ signal ])
      outcome = score!(signal.fingerprint, current_signals: [ signal ])

      expect(outcome.status).to eq("ineffective")
    end
  end
end
