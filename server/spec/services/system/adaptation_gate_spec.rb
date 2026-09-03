# frozen_string_literal: true

require "rails_helper"

# IMP-8c37b9e5ccd5 (INC-2) — the fleet half of core's `adaptation_gate` seam.
#
# Core composes an `adaptation_diff` plan and must not apply it on its own
# authority. This class answers the one question core is allowed to ask —
# "may this plan be applied now?" — from the SAME gate every other fleet
# remediation passes: Ai::InterventionPolicy resolution plus the Fleet Autonomy
# agent's Ai::ApprovalChain. A second approval namespace was explicitly
# rejected, so nothing here mints its own chain shape.
#
# Two invariants this spec exists to hold:
#   1. Core's bounds verdict may only NARROW. `auto_apply_eligible: false`
#      forces the require_approval arm no matter what the operator policy says,
#      so a policy can never widen core's replica ceiling.
#   2. Re-asking about a plan that is already before the gate does NOT mint a
#      second request. That is what lets the sensor path (gated BEFORE
#      composition) and the operator path share one queue.
RSpec.describe System::AdaptationGate do
  before do
    skip "requires Ai::ApprovalChain" unless defined?(::Ai::ApprovalChain)
  end

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let!(:agent) do
    create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy")
  end
  let!(:chain) do
    create(:ai_approval_chain, account: account,
           trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
  end

  let(:goal) do
    Ai::AgentGoal.create!(
      account: account, agent: agent, title: "Adapt", goal_type: "improvement",
      status: "pending", priority: 3, progress: 0.0, success_criteria: {}, metadata: {}
    )
  end
  let(:mission) do
    create(:ai_mission, account: account, created_by: user, mission_type: "infrastructure",
                        configuration: { "watch_policies" => { "auto_scale_max_replicas" => 8 } })
  end
  let(:plan) do
    Ai::GoalPlan.create!(
      account: account, goal: goal, agent: agent, status: "draft", version: 2,
      plan_data: { "kind" => "adaptation_diff", "change_type" => "scale_horizontal",
                   "signal_kind" => "system.project_slo_violation",
                   "signal_fingerprint" => "slo:mission:p99",
                   "signal_payload" => { "_sensor" => "ProjectSloSensor",
                                         "correlation_id" => "corr-1" },
                   "mission_id" => mission.id }
    )
  end

  # Production seeds a policy PER change_type
  # (system_provisioning_intervention_policies.rb), so a scale_horizontal
  # adaptation resolves `project.scale_horizontal` — not the coarse
  # `project.adapt` the signal-level bindings use.
  def policy!(policy, category: "project.scale_horizontal")
    Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: agent.id, scope: "agent",
      action_category: category, policy: policy, priority: 100, is_active: true
    )
  end

  def disposition(auto_apply_eligible: true, change_type: "scale_horizontal")
    described_class.adaptation_disposition(
      account: account, mission: mission, plan: plan,
      change_type: change_type, auto_apply_eligible: auto_apply_eligible
    )
  end

  describe ".adaptation_disposition" do
    it "grants auto-apply when the operator policy proceeds AND core says in-bounds" do
      policy!("notify_and_proceed")

      expect(disposition[:disposition]).to eq("auto_apply_within_bounds")
      # Ground truth: nothing was queued for a human.
      expect(Ai::ApprovalRequest.where(account: account).count).to eq(0)
    end

    it "routes to the fleet ApprovalRequest chain when the policy requires approval" do
      policy!("require_approval")

      answer = disposition

      expect(answer[:disposition]).to eq("routed")
      request = Ai::ApprovalRequest.where(account: account).first
      expect(request).to be_present
      expect(answer[:approval_request_id]).to eq(request.id)
      expect(request.status).to eq("pending")
      expect(request.approval_chain_id).to eq(chain.id)
      # The plan travels with the request so the approved lane can find it.
      expect(request.request_data.dig("payload", "plan_id")).to eq(plan.id)
      expect(request.request_data["action_category"]).to eq("project.scale_horizontal")
    end

    it "FORCES approval for an out-of-bounds plan even under a proceed policy" do
      policy!("notify_and_proceed")

      answer = disposition(auto_apply_eligible: false)

      expect(answer[:disposition]).to eq("routed")
      expect(Ai::ApprovalRequest.where(account: account).count).to eq(1)
    end

    it "routes a cost_control change through its own action category" do
      policy!("require_approval", category: "project.cost_control")

      answer = disposition(change_type: "cost_control")

      expect(answer[:disposition]).to eq("routed")
      expect(Ai::ApprovalRequest.where(account: account).first.request_data["action_category"])
        .to eq("project.cost_control")
    end

    # The seeded policy surface is per change_type: relocate, schema_change and
    # security_change are `require_approval` while scale_horizontal is
    # `auto_approve`. Collapsing them onto `project.adapt` made five of those
    # six policies unreachable — an operator setting `project.relocate` to
    # require_approval would have had no effect, because the coarse category
    # resolved notify_and_proceed instead.
    it "honors the operator's per-change_type policy for a relocate" do
      policy!("notify_and_proceed")                            # project.scale_horizontal
      policy!("require_approval", category: "project.relocate")

      answer = disposition(change_type: "relocate")

      expect(answer[:disposition]).to eq("routed")
      expect(Ai::ApprovalRequest.where(account: account).first.request_data["action_category"])
        .to eq("project.relocate")
    end

    it "falls back to project.adapt for a change_type with no category of its own" do
      policy!("require_approval", category: "project.adapt")

      answer = disposition(change_type: "something_new")

      expect(answer[:disposition]).to eq("routed")
      expect(Ai::ApprovalRequest.where(account: account).first.request_data["action_category"])
        .to eq("project.adapt")
    end

    it "does not mint a second request when the plan is already before the gate" do
      policy!("require_approval")
      first = disposition

      second = disposition

      expect(Ai::ApprovalRequest.where(account: account).count).to eq(1)
      expect(second[:disposition]).to eq("routed")
      expect(second[:approval_request_id]).to eq(first[:approval_request_id])
    end

    it "clears the plan once its own request is APPROVED — the same queue releases it" do
      policy!("require_approval")
      routed = disposition
      Ai::ApprovalRequest.find(routed[:approval_request_id]).update!(status: "approved")

      answer = disposition

      expect(answer[:disposition]).to eq("auto_apply_within_bounds")
      expect(Ai::ApprovalRequest.where(account: account).count).to eq(1)
    end

    it "releases an OUT-OF-BOUNDS plan on approval, declaring approval authority" do
      # Core's bounds check exists to stop the MACHINE applying a large change
      # unattended — not to veto an operator who looked at that change and said
      # yes. Making approval inert here would leave `routed` a dead end for
      # exactly the plans that most need a person. Core distinguishes the two
      # cases by the declared `authority`, never by inferring one from the
      # presence of a request id.
      policy!("require_approval")
      routed = disposition
      Ai::ApprovalRequest.find(routed[:approval_request_id]).update!(status: "approved")

      answer = disposition(auto_apply_eligible: false)

      expect(answer[:disposition]).to eq("auto_apply_within_bounds")
      expect(answer[:authority]).to eq("approval")
    end

    it "declares POLICY authority for an unattended proceed, so core's bounds still bind it" do
      policy!("notify_and_proceed")

      expect(disposition[:authority]).to eq("policy")
    end

    # HIER-P2DECL: project.* is declared on the Capacity Manager, so the gate
    # is that agent's — chain, policy row and the agent_id on the request —
    # reached through FleetAutonomyService#for_owner exactly as the three
    # project_* signal bindings are. The examples above keep the row on Fleet
    # Autonomy with no Capacity Manager seeded, which is the wave-1 fallback
    # (Fleet Autonomy gates, with a fleet.owner_agent_missing event).
    describe "the declared owner (Capacity Manager)" do
      let!(:capacity) do
        identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("capacity-manager")
        create(:ai_agent, account: account, agent_type: identity[:agent_type], name: identity[:name],
                          source_key: "capacity-manager")
      end
      let!(:capacity_chain) do
        create(:ai_approval_chain, account: account,
               trigger_type: "autonomy_action", name: "Capacity Manager Actions")
      end

      it "routes to the Capacity Manager's chain from the Capacity Manager's row, not Fleet Autonomy's" do
        # The row is on the OWNER; a Fleet-Autonomy row for the same category
        # would be the decoy the reconciler re-homes.
        Ai::InterventionPolicy.create!(
          account: account, ai_agent_id: capacity.id, scope: "agent",
          action_category: "project.scale_horizontal", policy: "require_approval", priority: 100, is_active: true
        )

        answer = disposition

        expect(answer[:disposition]).to eq("routed")
        request = Ai::ApprovalRequest.find(answer[:approval_request_id])
        expect(request.approval_chain_id).to eq(capacity_chain.id)
        expect(request.request_data["agent_id"]).to eq(capacity.id)
        expect(request.request_data["agent_key"]).to eq("capacity-manager")
        expect(System::FleetEvent.where(account: account,
                                        kind: System::Fleet::FleetAutonomyService::OWNER_MISSING_EVENT_KIND)).to be_empty
      end

      it "no longer reads a row left on Fleet Autonomy once the owner exists (policy_missing, not the tuned verb)" do
        policy!("notify_and_proceed") # on Fleet Autonomy — the former owner

        answer = disposition

        expect(answer[:disposition]).to eq("routed")
        expect(answer[:cause]).to eq(described_class::CAUSE_POLICY_MISSING)
        expect(answer[:detail]).to include("Capacity Manager")
      end
    end

    it "emits the owner-missing event and gates under Fleet Autonomy while the Capacity Manager is unseeded" do
      policy!("require_approval")

      disposition

      warned = System::FleetEvent.where(account: account,
                                        kind: System::Fleet::FleetAutonomyService::OWNER_MISSING_EVENT_KIND)
      expect(warned.count).to eq(1)
      expect(warned.last.payload).to include("owner" => "capacity-manager", "fallback_agent_id" => agent.id)
      expect(Ai::ApprovalRequest.where(account: account).first.approval_chain_id).to eq(chain.id)
    end

    it "returns nil when no Fleet Autonomy agent is seeded — core parks the plan" do
      # An account with agents but no Fleet Autonomy one: there is no gate to
      # ask, so the honest answer is "I cannot say", and core parks rather than
      # proceeds.
      agent.update!(name: "Some Other Agent")

      expect(disposition).to be_nil
    end

    it "routes rather than proceeding when the policy blocks the category" do
      policy!("block")

      answer = disposition

      expect(answer[:disposition]).to eq("routed")
      expect(answer[:detail]).to match(/block/i)
    end
  end

  # IMP-7a6c9a70e050 — TWO FAILURES BEHIND ONE :blocked ARM, AGAIN.
  #
  # This class is a SECOND router: it maps a change_type onto a
  # `project.<change_type>` category that DecisionEngine::SIGNAL_BINDINGS never
  # names, and hands it to the same FleetAutonomyService#gate_action!. The
  # misconfigured-lane seam (System::Autonomy::RoutedLaneGuard, IMP-5a450411d873
  # / IMP-b400ec1a2df8) could not see those four categories, so a MISSING policy
  # row took the quiet `not_permitted` arm and arrived here labelled
  # CAUSE_POLICY_BLOCKED — "blocked by policy" for a lane no policy has ever
  # answered. An operator was sent to policy tuning when the fix was re-running
  # a seed.
  #
  # BOTH DIRECTIONS ARE ASSERTED. A change that collapsed the two into
  # policy_missing would be the same misdiagnosis pointed the other way —
  # reporting an operator's deliberate block as a deploy defect — and a
  # one-directional oracle passes it.
  describe "the two failures wearing the :blocked arm" do
    def request_count = ::Ai::ApprovalRequest.where(account: account).count

    context "a routed category with NO policy row (nothing answered)" do
      it "declares policy_missing, not an operator's block" do
        answer = disposition

        expect(answer[:disposition]).to eq("routed")
        expect(answer[:cause]).to eq(::System::Autonomy::RoutedLaneGuard::GATE_POLICY_MISSING)
        expect(answer[:approval_request_id]).to be_nil
      end

      # The detail string is what an operator reads. "blocked by policy" is the
      # sentence that sent them to the Autonomy modal instead of the seed.
      it "does not describe the absence of configuration as a policy decision" do
        expect(disposition[:detail].to_s).not_to match(/blocked by policy/)
      end

      it "lands no write" do
        expect { disposition }.not_to change { request_count }
        expect(plan.reload.status).to eq("draft")
      end
    end

    context "a routed category with an EXPLICIT block row (the operator answered)" do
      before { policy!("block") }

      it "still declares policy_blocked" do
        answer = disposition

        expect(answer[:disposition]).to eq("routed")
        expect(answer[:cause]).to eq(described_class::CAUSE_POLICY_BLOCKED)
        expect(answer[:cause]).not_to eq(::System::Autonomy::RoutedLaneGuard::GATE_POLICY_MISSING)
      end

      it "lands no write" do
        expect { disposition }.not_to change { request_count }
        expect(plan.reload.status).to eq("draft")
      end
    end

    # The four categories this offer is about. project.adapt and
    # project.cost_control were already visible through SIGNAL_BINDINGS; these
    # are the ones only this router names, and each must reach the seam.
    #
    # The category comes from the change_type ARGUMENT, which is what
    # AdaptationDispatchService passes; plan_data's own change_type is not
    # consulted here, so it deliberately stays at the shared fixture value.
    %w[relocate schema_change security_change scale_horizontal].each do |change_type|
      it "reports a missing row for #{change_type} as policy_missing" do
        answer = disposition(change_type: change_type)

        expect(answer[:cause]).to eq(::System::Autonomy::RoutedLaneGuard::GATE_POLICY_MISSING)
      end
    end
  end

  # IMP-fec9abb225c6 (1) — close_plan! rejected a plan in ANY status.
  #
  # Its only guard was `plan.status == "rejected"`, and Ai::GoalPlan#reject! is a
  # bare update! with no state machine, so a plan whose latest approval request
  # becomes cancelled/expired AFTER dispatch flipped to `rejected` while its
  # appended steps kept running on the mission's live plan. Two consequences,
  # both state corruption rather than cosmetics:
  #
  #   * settle! scopes to status "executing", so the plan never settles and no
  #     RemediationOutcome is ever minted for it.
  #   * in_flight_adaptation_plan no longer sees it, so the next breach composes
  #     a SECOND plan and appends more steps while the first set still runs.
  #
  # Driven at close_plan! directly, per the direction: reaching this through the
  # approve -> dispatch path is impossible, because it needs a mid-execution
  # policy change to decide an already-dispatched plan's request.
  describe "closing a plan whose request was decided after dispatch" do
    def close!(plan_status, request_status: "expired")
      plan.update!(status: plan_status)
      described_class.send(:close_plan!, plan, request_status)
      plan.reload.status
    end

    it "leaves an executing plan alone" do
      expect(close!("executing")).to eq("executing"),
                                     "an executing adaptation was flipped to rejected while its appended steps " \
                                     "keep running — it can never settle and the next breach appends a second set"
    end

    it "leaves an approved plan alone" do
      expect(close!("approved")).to eq("approved")
    end

    # CONTROLS: the states where closing the proposal IS meaningful must still
    # close. A guard that refused everything would satisfy the examples above
    # and silently strand every genuinely undispatched proposal.
    it "still closes a draft plan" do
      expect(close!("draft")).to eq("rejected")
    end

    it "still closes a validated plan" do
      expect(close!("validated")).to eq("rejected")
    end

    it "stays a no-op on an already rejected plan" do
      expect(close!("rejected")).to eq("rejected")
    end
  end

  describe ".record_adaptation_outcome!" do
    it "mints a pending RemediationOutcome the validator can later score" do
      outcome = described_class.record_adaptation_outcome!(
        account: account, mission: mission, plan: plan,
        fingerprint: "slo:mission:p99", signal_kind: "system.project_slo_violation"
      )

      expect(outcome).to be_present
      row = System::Fleet::RemediationOutcome.find(outcome.id)
      expect(row.status).to eq("pending")
      expect(row.fingerprint).to eq("slo:mission:p99")
      expect(row.signal_kind).to eq("system.project_slo_violation")
      expect(row.action_category).to eq("project.scale_horizontal")
      expect(row.resource_ref).to eq(mission.id)
      expect(row.correlation_id).to eq("corr-1")
      # Sensor provenance is what lets RemediationValidator tell "the signal
      # cleared" from "the sensor crashed and its fingerprints vanished".
      expect(row.metadata["sensor"]).to eq("ProjectSloSensor")
      expect(row.metadata["plan_id"]).to eq(plan.id)
      expect(row.settle_until).to be > row.acted_at
    end

    it "is the row RemediationValidator flips pending -> effective on fingerprint clear" do
      described_class.record_adaptation_outcome!(
        account: account, mission: mission, plan: plan,
        fingerprint: "slo:mission:p99", signal_kind: "system.project_slo_violation"
      )
      System::Fleet::RemediationOutcome.where(account: account)
        .update_all(settle_until: 1.minute.ago)

      # A later sense pass in which the breach no longer fires.
      result = System::Fleet::RemediationValidator
        .new(account: account, agent: agent)
        .validate_due!(current_signals: [], failed_sensors: [])

      expect(result[:effective]).to eq(1)
      expect(System::Fleet::RemediationOutcome.where(account: account).first.status)
        .to eq("effective")
    end

    it "scores INEFFECTIVE when the same fingerprint is still firing" do
      described_class.record_adaptation_outcome!(
        account: account, mission: mission, plan: plan,
        fingerprint: "slo:mission:p99", signal_kind: "system.project_slo_violation"
      )
      System::Fleet::RemediationOutcome.where(account: account)
        .update_all(settle_until: 1.minute.ago)

      still_firing = System::Fleet::Signal.new(
        kind: "system.project_slo_violation", severity: "high",
        payload: { "mission_id" => mission.id, "_sensor" => "ProjectSloSensor" },
        fingerprint: "slo:mission:p99"
      )
      result = System::Fleet::RemediationValidator
        .new(account: account, agent: agent)
        .validate_due!(current_signals: [ still_firing ], failed_sensors: [])

      expect(result[:ineffective]).to eq(1)
    end

    it "does not stack a second pending outcome for the same fingerprint" do
      2.times do
        described_class.record_adaptation_outcome!(
          account: account, mission: mission, plan: plan,
          fingerprint: "slo:mission:p99", signal_kind: "system.project_slo_violation"
        )
      end

      expect(System::Fleet::RemediationOutcome.where(account: account).count).to eq(1)
    end
  end

  # IMP-fec9abb225c6 (5) — settle_failed_outcome! matched ANY pending row for
  # the fingerprint, so a failure could re-label a row it never minted.
  #
  # This is instrument corruption, not a cosmetic bug: RemediationOutcome is the
  # ground-truth table the LEARN step reads, so a fabricated `ineffective`
  # both invents a data point and pushes two genuine failures toward
  # STUCK_STREAK_THRESHOLD. Both mints already carry metadata["plan_id"], so the
  # in-place settle can be scoped to the row THIS plan minted.
  describe "settling a failure when another lane holds a pending row" do
    let(:other_plan) do
      Ai::GoalPlan.create!(account: account, goal: goal, agent: agent, status: "executing",
                           version: 3, plan_data: plan.plan_data)
    end

    let!(:foreign_pending) do
      System::Fleet::RemediationOutcome.create!(
        account: account, agent_id: agent.id, signal_kind: "system.project_slo_violation",
        fingerprint: "slo:mission:p99", action_category: "project.scale_horizontal",
        status: "pending", acted_at: Time.current, settle_until: 1.hour.from_now,
        metadata: { "gate" => "adaptation_applied", "plan_id" => other_plan.id }
      )
    end

    it "does not re-label a pending row minted by a different plan" do
      described_class.send(:settle_failed_outcome!, account, plan,
                           "slo:mission:p99", "system.project_slo_violation")

      expect(foreign_pending.reload.status).to eq("pending"),
                                               "a failure re-labelled another plan's still-settling success as " \
                                               "ineffective — that fabricates a row in the table LEARN reads"
    end

    it "mints its own ineffective row instead" do
      expect {
        described_class.send(:settle_failed_outcome!, account, plan,
                             "slo:mission:p99", "system.project_slo_violation")
      }.to change { System::Fleet::RemediationOutcome.where(status: "ineffective").count }.by(1)

      mine = System::Fleet::RemediationOutcome.where(status: "ineffective").last
      expect(mine.metadata["plan_id"]).to eq(plan.id)
    end

    # CONTROL: settling in place is still correct for THIS plan's own pending
    # row — that is the case the method exists for, and scoping must not break
    # it into a duplicate.
    it "still settles this plan's own pending row in place" do
      own = System::Fleet::RemediationOutcome.create!(
        account: account, agent_id: agent.id, signal_kind: "system.project_slo_violation",
        fingerprint: "slo:mission:other", action_category: "project.scale_horizontal",
        status: "pending", acted_at: Time.current, settle_until: 1.hour.from_now,
        metadata: { "gate" => "adaptation_applied", "plan_id" => plan.id }
      )

      expect {
        described_class.send(:settle_failed_outcome!, account, plan,
                             "slo:mission:other", "system.project_slo_violation")
      }.not_to change { System::Fleet::RemediationOutcome.count }

      expect(own.reload.status).to eq("ineffective")
    end
  end

  describe "registry wiring" do
    it "is reachable as the adaptation_gate provider" do
      expect(::Powernode::ExtensionRegistry.provider(:adaptation_gate)).to eq(described_class)
    end
  end
end
