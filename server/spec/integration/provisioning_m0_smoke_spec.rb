# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning plan — slice 6 (M0 end-to-end smoke).
#
# Drives the full M0 conversation pipeline through the *service* layer, no
# HTTP. Per the team-lead's tightened scope:
#
#   IntentCaptureService → PlanComposerService → OrchestratorService
#   → SkillCompositionRunner → ProvisionFullStackExecutor
#
# Stub seams (one canonical seam per concern):
#   - IntentCaptureService#capture           → fixed brief Hash
#   - GoalDecompositionService#decompose     → real Ai::GoalPlan with 3 steps
#   - WorkerJobService.enqueue_job           → no-op for phase jobs;
#                                              for "AiProvisioningStepJob"
#                                              cascades into runner.execute_step!
#                                              so the DAG unfolds in-process
#   - ProvisioningService.provision_instance → creates real NodeInstance rows,
#                                              returns Runtime::Result.ok
#                                              (skips the LocalQemuProvider →
#                                              CloudSeed → Vault chain, which
#                                              is exercised by node_provisioning_
#                                              integration_spec at a lower layer)
#
# What this asserts:
#   1. Mission is created with mission_type=infrastructure and the
#      system_provisioning template is auto-assigned by set_defaults.
#   2. After IntentCaptureService.capture: brief lands in mission.configuration.
#   3. After PlanComposerService.compose!: 3 GoalPlanSteps with
#      step_type "provisioning_skill" and execution_config.skill ==
#      "provision_full_stack".
#   4. After approval at "review_plan": mission phase advances to "execute".
#   5. After SkillCompositionRunner.execute!: 3 NodeInstances exist + each
#      step is marked "completed" + ProvisioningService.provision_instance
#      called exactly 3 times.
#   6. After approval at "handoff": mission phase advances to "adapting".
#
# Side notes (not asserted here, deferred to follow-ups):
#   - LocalQemuProvider RecorderRunner invocation count — see node_provisioning
#     spec for the lower-layer assertion. Bringing it in here would require
#     stubbing CloudSeed.build / DomainXmlBuilder.build to skip Vault.
#   - rollback_provision_full_stack — the runner calls the rollback hook on an
#     instance with kwargs (`executor.public_send(hook, **outputs)`), but our
#     descriptor names a class method taking a positional execution_record.
#     Requires either an instance shim on the executor or a runner adjustment.
#     Tracked separately; not on the green path.
RSpec.describe "AI-driven provisioning M0 end-to-end smoke", type: :integration do
  # PermissionTestHelpers is auto-included for :request/:controller/:model types
  # but not :integration; pull it in by hand so user_with_permissions works.
  include PermissionTestHelpers

  let(:account)        { create(:account) }
  let(:admin)          { user_with_permissions("ai.workflows.create", "ai.workflows.execute", account: account) }
  let(:agent)          { create(:ai_agent, account: account) }
  let(:architecture)   { create(:system_node_architecture, :with_checksums) }
  let(:platform)       { create(:system_node_platform, account: account, node_architecture: architecture) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:provider)       { create(:system_provider, account: account, provider_type: "local_qemu") }
  let(:region)         { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type)  { create(:system_provider_instance_type, account: account, provider: provider) }

  # Side-business persona brief per team-lead's spec.
  let(:fixed_brief) do
    {
      "intent" => "Provision a 3-region web app with Postgres + Redis",
      "use_case" => "side-business 10k MAU web app, primary in us-east, anycast IP, nightly backups",
      "scale" => { "initial" => 3, "target" => 5, "growth_profile" => "linear" },
      "regions" => ["us-east-1", "eu-west-1", "ap-southeast-1"],
      "compliance" => [],
      "budget_cap_usd_monthly" => 200.0,
      "latency_targets_ms" => { "p99" => 250 },
      "data_residency" => [],
      "preferred_provider" => "local_qemu"
    }
  end

  # Captured-by-stub container so the WorkerJobService stub can route step
  # job dispatches back into the real runner instance.
  let(:runner_holder) { { runner: nil } }

  before do
    # Force account+agent fixtures to materialize before seeds run (the skills
    # seed otherwise sees no Account.first and bails). Then load only the
    # mission template seed — the SkillCompositionRunner resolves executors
    # by class-name convention (camelize + "Executor"), so the Ai::Skill DB
    # row isn't on the smoke path; that registration is exercised by the
    # standalone seed run from task #4.
    account
    agent
    load Rails.root.join("../extensions/system/server/db/seeds/system_provisioning_mission_template.rb")

    # LocalQemuProvider runner gets swapped to the recording adapter as a
    # benign default; the smoke test's provisioning is intercepted higher up.
    System::Providers::LocalQemuProvider.runner = System::Providers::LocalQemu::RecorderRunner.new

    # === Stub seam 1: IntentCaptureService.capture → fixed brief ===
    allow_any_instance_of(Ai::Provisioning::IntentCaptureService).to receive(:capture)
      .and_return(brief: fixed_brief, missing_fields: [])

    # === Stub seam 2: GoalDecompositionService#decompose → real GoalPlan ===
    # 3 parallel provision_full_stack steps (no inter-step deps, count=1 each).
    allow_any_instance_of(Ai::Autonomy::GoalDecompositionService).to receive(:decompose) do |_svc, goal|
      plan = Ai::GoalPlan.create!(
        account: account, goal: goal, agent: agent,
        status: "draft", version: 1
      )
      3.times do |i|
        plan.steps.create!(
          step_number: i + 1,
          step_type: "agent_execution", # rewritten to provisioning_skill by composer
          description: "Provision instance #{i + 1}",
          dependencies: [],
          execution_config: {
            "skill" => "provision_full_stack",
            "inputs" => {
              "template_id" => template.id,
              "count" => 1,
              "provider_region_id" => region.id,
              "provider_instance_type_id" => instance_type.id
            },
            "on_failure" => "continue"
          }
        )
      end
      plan
    end

    # === Stub seam 3: WorkerJobService.enqueue_job ===
    # Phase jobs (AiProvisioning*Job) are no-ops — we drive each phase manually.
    # AiProvisioningStepJob dispatches cascade into the captured runner so the
    # full DAG unfolds in-process.
    allow(WorkerJobService).to receive(:enqueue_job) do |*positional, **kwargs|
      klass = positional.first
      if klass == "AiProvisioningStepJob" && runner_holder[:runner]
        args_hash = kwargs[:args]
        args_hash = args_hash.first if args_hash.is_a?(Array)
        step_id = args_hash.is_a?(Hash) ? (args_hash[:step_id] || args_hash["step_id"]) : nil
        step = Ai::GoalPlanStep.find_by(id: step_id) if step_id
        runner_holder[:runner].execute_step!(step) if step
      end
      true
    end

    # === Stub seam 4: ProvisioningService.provision_instance ===
    # Creates real NodeInstance rows on each call; the rest of the lower
    # provider chain is below this smoke test's scope.
    allow(System::ProvisioningService).to receive(:provision_instance) do |*_positional, **kwargs|
      node = kwargs[:node]
      ni = System::NodeInstance.create!(
        name: "smoke-#{node.name}-#{SecureRandom.hex(2)}",
        node: node,
        variety: "cloud",
        # DB-level check constraint allows only:
        # pending, provisioning, running, stopped, terminated, error
        status: "pending",
        provider_region_id: kwargs[:provider_region_id],
        provider_instance_type_id: kwargs[:provider_instance_type_id]
      )
      System::Runtime::Result.ok(data: { instance: ni, cloud_instance_id: "ci-#{ni.id[0..7]}" })
    end
  end

  after do
    System::Providers::LocalQemuProvider.reset_runner!
  end

  it "drives a mission from intent capture through provisioning to handoff" do
    # ---------- 1. Mission creation -----------------------------------------
    mission = Ai::Mission.create!(
      account: account,
      created_by: admin,
      name: "Smoke: 3-region web app",
      mission_type: "infrastructure",
      objective: "side-business smoke test",
      status: "draft"
    )

    expect(mission.mission_template).to be_present
    expect(mission.mission_template.name).to eq("system_provisioning")
    expect(mission.phases_for_type).to eq(%w[capture_intent compose_plan review_plan execute verify handoff adapting])

    orchestrator = Ai::Missions::OrchestratorService.new(mission: mission)

    # ---------- 2. Start: capture_intent phase ------------------------------
    orchestrator.start!
    expect(mission.reload.status).to eq("active")
    expect(mission.current_phase).to eq("capture_intent")

    # Run intent capture (the worker job that would do this is stubbed); write
    # the brief into mission.configuration so PlanComposer can pick it up.
    capture_result = Ai::Provisioning::IntentCaptureService.new(account: account, user: admin)
                                                           .capture(natural_language: "Provision 3 web servers")
    expect(capture_result[:brief]).to include("intent", "regions", "budget_cap_usd_monthly")
    expect(capture_result[:brief]["budget_cap_usd_monthly"]).to eq(200.0)
    expect(capture_result[:missing_fields]).to be_empty

    mission.update!(configuration: mission.configuration.merge("brief" => capture_result[:brief]))
    expect(mission.reload.configuration["brief"]).to include("intent")

    # ---------- 3. Advance: compose_plan phase ------------------------------
    orchestrator.advance!(result: { brief_captured: true })
    expect(mission.reload.current_phase).to eq("compose_plan")

    # Run plan composition.
    plan = Ai::Provisioning::PlanComposerService.new(account: account, mission: mission).compose!
    expect(plan).to be_a(Ai::GoalPlan)
    expect(plan.steps.count).to eq(3)
    plan.steps.in_order.each_with_index do |step, i|
      expect(step.step_type).to eq("provisioning_skill"), "step #{i + 1} step_type was #{step.step_type}"
      expect(step.execution_config["skill"]).to eq("provision_full_stack")
      expect(step.execution_config["inputs"]).to include("template_id", "count", "brief")
    end

    # Stash the plan_id where the next phase can find it.
    mission.update!(configuration: mission.configuration.merge("plan" => { "id" => plan.id }))

    # ---------- 4. Advance: review_plan (approval gate, no auto-dispatch) --
    orchestrator.advance!(result: { plan_id: plan.id })
    expect(mission.reload.current_phase).to eq("review_plan")
    expect(mission.awaiting_approval?).to be true

    # ---------- 5. Approval at review_plan → execute -----------------------
    orchestrator.handle_approval!(gate: "review_plan", user: admin, decision: "approved")
    expect(mission.reload.current_phase).to eq("execute")
    expect(mission.awaiting_approval?).to be false

    # ---------- 6. Run the SkillCompositionRunner --------------------------
    runner = Ai::Provisioning::SkillCompositionRunner.new(account: account, mission: mission, plan: plan)
    runner_holder[:runner] = runner

    runner.execute! # cascades through the WorkerJobService stub

    # ---------- 7. Provisioning assertions ---------------------------------
    expect(System::ProvisioningService).to have_received(:provision_instance).exactly(3).times

    created_nodes = System::Node.where(account: account, node_template: template)
    expect(created_nodes.count).to eq(3)

    created_instances = System::NodeInstance.where(node_id: created_nodes.pluck(:id))
    expect(created_instances.count).to eq(3)

    plan.steps.reload.each do |step|
      expect(step.status).to eq("completed"), "step #{step.step_number} status was #{step.status}"
    end

    # Capture provisioned-resource ids on the mission (the AiProvisioningExecuteJob
    # would do this in production; we do it inline since that job is stubbed).
    instance_ids = created_instances.pluck(:id)
    mission.update!(
      configuration: mission.configuration.deep_merge(
        "provisioned_resources" => { "node_instance_ids" => instance_ids }
      )
    )

    # ---------- 8. Advance: verify -----------------------------------------
    orchestrator.advance!(result: { provisioned_count: 3 })
    expect(mission.reload.current_phase).to eq("verify")

    # ---------- 9. Advance: handoff (approval gate) ------------------------
    orchestrator.advance!(result: { slo_targets_met: true })
    expect(mission.reload.current_phase).to eq("handoff")
    expect(mission.awaiting_approval?).to be true

    # ---------- 10. Approval at handoff → adapting -------------------------
    orchestrator.handle_approval!(gate: "handoff", user: admin, decision: "approved")
    expect(mission.reload.current_phase).to eq("adapting")
    expect(mission.status).to eq("active") # adapting is a long-lived live phase
    expect(mission.configuration.dig("provisioned_resources", "node_instance_ids").size).to eq(3)
  end
end
