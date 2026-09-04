# frozen_string_literal: true

require "rails_helper"

# IMP-8c37b9e5ccd5 (INC-2) — the adaptation lane end to end, with NOTHING
# stubbed between core and the fleet gate.
#
# Every other spec for this increment exercises one half: core's specs stub the
# `adaptation_gate` seam, and adaptation_gate_spec drives the provider directly.
# Both can be green while the two halves never meet — the failure mode this
# campaign has hit four times ("a fix is only real if it runs on the path
# production takes"). So this spec resolves the gate through the REAL registry,
# against REAL seeded intervention policies, and asserts ground-truth ROWS at
# every hop:
#
#   compose  → a draft adaptation_diff plan
#   gate     → a real Ai::ApprovalRequest, plan still draft, live plan untouched
#   approve  → the live plan GROWS the appended step and a step job goes out
#   execute  → steps complete
#   settle   → post-adapt verification, then a pending RemediationOutcome
#   validate → the ordinary fleet validator flips it to EFFECTIVE on
#              fingerprint clear
#
# The only stubs are the two things that would reach outside this process: the
# worker job dispatch and the live-provider reconciler.
RSpec.describe "adaptation lane end to end", type: :integration do
  before do
    skip "requires Ai::ApprovalChain" unless defined?(::Ai::ApprovalChain)
    allow(WorkerJobService).to receive(:enqueue_job).and_return(true)

    # The live-provider half of verification. Fixture instance ids have no
    # NodeInstance rows; provider reconciliation is verified by
    # provision_verifier_spec, and standing it in here keeps THIS spec's
    # subject the lane rather than the provider.
    reconciler = double("provision_verifier")
    allow(reconciler).to receive(:reconcile_instances) do |account:, expectations:|
      expectations.map { |e| { node_instance_id: e[:node_instance_id], ok: true, detail: "running" } }
    end
    allow(::Powernode::ExtensionRegistry).to receive(:provider).and_call_original
    allow(::Powernode::ExtensionRegistry).to receive(:provider)
      .with(:provision_verifier).and_return(reconciler)
  end

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let!(:fleet_agent) do
    create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy")
  end
  let!(:chain) do
    create(:ai_approval_chain, account: account,
           trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
  end

  # The production policy for this change type, as
  # PolicyDeclarations::PROVISIONING_POLICIES declares it.
  let!(:policy) do
    Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: fleet_agent.id, scope: "agent",
      action_category: "project.scale_horizontal", policy: "require_approval",
      priority: 10, is_active: true
    )
  end

  let(:goal) do
    Ai::AgentGoal.create!(
      account: account, agent: fleet_agent, title: "Provision", goal_type: "improvement",
      status: "pending", priority: 3, progress: 0.0, success_criteria: {}, metadata: {}
    )
  end

  # The mission's live plan, with the completed provision step whose inputs are
  # the footprint a scale-out must replicate.
  let!(:live_plan) do
    plan = Ai::GoalPlan.create!(account: account, goal: goal, agent: fleet_agent,
                                status: "executing", version: 1,
                                plan_data: { "kind" => "provisioning" })
    plan.steps.create!(
      step_number: 1, step_type: "provisioning_skill", status: "completed",
      description: "Provision full stack", dependencies: [],
      execution_config: { "skill" => "provision_full_stack", "on_failure" => "rollback",
                          "inputs" => { "count" => 3, "template_id" => "tmpl-1",
                                        "provider_region_id" => "region-1",
                                        "provider_instance_type_id" => "itype-1" } },
      metadata: { "last_outputs" => { "outputs" => { "node_instance_ids" => %w[i-1 i-2 i-3] },
                                      "failures" => [] } }
    )
    plan
  end

  let(:mission) do
    create(:ai_mission, account: account, created_by: user, mission_type: "infrastructure",
                        configuration: {
                          "brief" => { "scale" => { "initial" => 3 }, "regions" => %w[us-east-1] },
                          "plan" => { "plan_id" => live_plan.id },
                          "watch_policies" => { "auto_scale_max_replicas" => 8 }
                        })
  end

  # A real sensor signal — the object ProjectSloSensor emits, carrying the
  # fingerprint the remediation outcome is ultimately scored by.
  let(:slo_signal) do
    System::Fleet::Signal.new(
      kind: "system.project_slo_violation",
      severity: "high",
      payload: {
        "mission_id" => mission.id, "metric" => "p99_latency_ms",
        "observed" => 500.0, "target" => 250.0, "breach_pct" => 100.0,
        "replica_count" => 3,
        "correlation_id" => "project_slo:#{mission.id}:1",
        "_sensor" => "ProjectSloSensor"
      },
      fingerprint: "project_slo_violation:#{mission.id}:p99_latency_ms"
    )
  end

  def dispatcher
    ::Ai::Provisioning::AdaptationDispatchService.new(account: account, mission: mission)
  end

  it "carries a sensor signal through gate, approval, execution, verification and validation" do
    # ---- compose (the real proposer, no LLM: scale_horizontal is deterministic)
    plan = ::Ai::Provisioning::AdaptationProposerService
      .new(account: account, mission: mission)
      .propose_from_signals(signals: [ slo_signal ])

    expect(plan).to be_present
    expect(plan.plan_data["kind"]).to eq("adaptation_diff")
    expect(plan.plan_data["signal_fingerprint"]).to eq(slo_signal.fingerprint)
    expect(plan.status).to eq("draft")
    # The proposer no longer mints its own approval object.
    expect(Ai::ApprovalRequest.where(account: account).count).to eq(0)

    # ---- gate (REAL registry → System::AdaptationGate → seeded policy)
    expect(::Powernode::ExtensionRegistry.provider(:adaptation_gate))
      .to eq(System::AdaptationGate)

    routed = dispatcher.dispatch!(plan: plan)

    expect(routed[:gate]).to eq("routed")
    expect(routed[:dispatched]).to be false
    request = Ai::ApprovalRequest.where(account: account).first
    expect(request).to be_present
    expect(request.status).to eq("pending")
    expect(request.request_data["action_category"]).to eq("project.scale_horizontal")
    # Ground truth: nothing ran.
    expect(plan.reload.status).to eq("draft")
    expect(live_plan.reload.steps.count).to eq(1)
    expect(WorkerJobService).not_to have_received(:enqueue_job)

    # Re-asking must not mint a second request — the sensor path and the
    # operator path share one queue.
    dispatcher.dispatch!(plan: plan.reload)
    expect(Ai::ApprovalRequest.where(account: account).count).to eq(1)

    # ---- approve, then re-dispatch: the same queue releases it
    request.update!(status: "approved")

    applied = dispatcher.dispatch!(plan: plan.reload)

    expect(applied[:gate]).to eq("auto_apply_within_bounds")
    expect(applied[:dispatched]).to be true

    live_plan.reload
    expect(live_plan.steps.count).to eq(2)
    appended = live_plan.steps.order(:step_number).last
    expect(appended.step_number).to eq(2)
    expect(appended.status).to eq("pending")
    expect(appended.execution_config["skill"]).to eq("scale_project")
    expect(appended.execution_config["adapted_from_plan_id"]).to eq(plan.id)
    expect(plan.reload.status).to eq("executing")
    expect(WorkerJobService).to have_received(:enqueue_job)
      .with("AiProvisioningStepJob", hash_including(args: hash_including(step_id: appended.id)))
      .once

    # ---- execute: the appended step lands its new replicas
    appended.update!(
      status: "completed",
      metadata: { "last_outputs" => { "outputs" => { "node_instance_ids" => %w[i-4 i-5] },
                                      "failures" => [] } }
    )

    # ---- settle: post-adapt verification, then the outcome row
    settled = dispatcher.settle!(adaptation_plan_ids: [ plan.id ])

    expect(settled[:healthy]).to be true
    expect(settled[:outcomes_recorded]).to eq(1)
    expect(plan.reload.status).to eq("completed")

    outcome = System::Fleet::RemediationOutcome.where(account: account).first
    expect(outcome).to be_present
    expect(outcome.status).to eq("pending")
    expect(outcome.fingerprint).to eq(slo_signal.fingerprint)
    expect(outcome.metadata["sensor"]).to eq("ProjectSloSensor")

    # ---- validate: the ORDINARY fleet validator, on a later tick where the
    # breach no longer fires, flips it to EFFECTIVE. Nothing in core re-senses.
    System::Fleet::RemediationOutcome.where(account: account)
      .update_all(settle_until: 1.minute.ago)

    result = System::Fleet::RemediationValidator
      .new(account: account, agent: fleet_agent)
      .validate_due!(current_signals: [], failed_sensors: [])

    expect(result[:effective]).to eq(1)
    expect(outcome.reload.status).to eq("effective")
  end

  it "scores the remediation INEFFECTIVE when the breach is still firing after it lands" do
    plan = ::Ai::Provisioning::AdaptationProposerService
      .new(account: account, mission: mission)
      .propose_from_signals(signals: [ slo_signal ])

    Ai::InterventionPolicy.where(account: account).update_all(policy: "notify_and_proceed")
    applied = dispatcher.dispatch!(plan: plan)
    expect(applied[:dispatched]).to be true

    live_plan.reload.steps.where(status: "pending").find_each do |s|
      s.update!(status: "completed",
                metadata: { "last_outputs" => { "outputs" => { "node_instance_ids" => %w[i-4 i-5] },
                                                "failures" => [] } })
    end
    dispatcher.settle!(adaptation_plan_ids: [ plan.id ])

    System::Fleet::RemediationOutcome.where(account: account)
      .update_all(settle_until: 1.minute.ago)

    result = System::Fleet::RemediationValidator
      .new(account: account, agent: fleet_agent)
      .validate_due!(current_signals: [ slo_signal ], failed_sensors: [])

    expect(result[:ineffective]).to eq(1)
    expect(System::Fleet::RemediationOutcome.where(account: account).first.status)
      .to eq("ineffective")
  end

  it "PARKS the plan in draft in core mode — no gate registered, nothing runs" do
    plan = ::Ai::Provisioning::AdaptationProposerService
      .new(account: account, mission: mission)
      .propose_from_signals(signals: [ slo_signal ])

    allow(::Powernode::ExtensionRegistry).to receive(:provider)
      .with(:adaptation_gate).and_return(nil)

    result = dispatcher.dispatch!(plan: plan)

    expect(result[:gate]).to eq("parked_gate_unavailable")
    expect(result[:dispatched]).to be false
    expect(plan.reload.status).to eq("draft")
    expect(live_plan.reload.steps.count).to eq(1)
    expect(Ai::ApprovalRequest.where(account: account).count).to eq(0)
    expect(WorkerJobService).not_to have_received(:enqueue_job)
    expect(System::Fleet::RemediationOutcome.where(account: account).count).to eq(0)
  end
end
