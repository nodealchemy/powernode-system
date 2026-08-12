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

  def policy!(policy, category: "project.adapt")
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
      expect(request.request_data["action_category"]).to eq("project.adapt")
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
      expect(row.action_category).to eq("project.adapt")
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

  describe "registry wiring" do
    it "is reachable as the adaptation_gate provider" do
      expect(::Powernode::ExtensionRegistry.provider(:adaptation_gate)).to eq(described_class)
    end
  end
end
