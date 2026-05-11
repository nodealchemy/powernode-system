# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning M3 — slice 5 (deploy-from-repo end-to-end smoke).
#
# Builds on the M0 smoke harness: drives the full provisioning conversation
# pipeline through the *service* layer (no HTTP) for the "Run My Code" path
# where the operator's brief carries a Git repo + start_command.
#
#   IntentCaptureService → PlanComposerService → OrchestratorService
#   → SkillCompositionRunner → ProvisionFullStackExecutor (provision step)
#                            → DeployAppCodeExecutor      (deploy step)
#                              → System::CodeDeployService.call (Slice A)
#
# What this asserts (per task #5, step 5):
#   1. Brief carrying repo_url + use_case=discord_bot composes a 2-step plan:
#      provision_full_stack (step 1) + deploy_app_code (step 2, depending on 1).
#   2. After provision_full_stack runs, a real System::NodeInstance exists.
#   3. After deploy_app_code runs (with System::CodeDeployService.call stubbed),
#      an Ai::ProvisioningCodeDeployment row exists with status=running and
#      commit_sha set from the stub's return value.
#   4. Mission reaches `verify` then `handoff` (gate, awaiting approval).
#   5. After handoff approval, mission lands in `adapting` (long-lived).
#
# Stub seams (kept minimal — most of the pipeline runs for real):
#   - IntentCaptureService#capture           → fixed brief Hash with repo_url
#   - GoalDecompositionService#decompose     → real Ai::GoalPlan with
#                                              ONE provision_full_stack step
#                                              (deploy_app_code gets appended
#                                              by PlanComposerService itself)
#   - WorkerJobService.enqueue_job           → cascade for AiProvisioningStepJob,
#                                              no-op for phase jobs
#   - ProvisioningService.provision_instance → real NodeInstance row + ok Result
#   - System::CodeDeployService.call         → success Hash with stub commit
#
# Known M3 integration gap surfaced by this spec:
#   PlanComposer's deploy_app_code step has no `node_instance_id` in its
#   inputs at compose time (the upstream provision step hasn't run yet).
#   The runtime threading mechanism (taking `node_instance_id` from the
#   provision step's outputs and merging into the deploy step's inputs)
#   does not exist in SkillCompositionRunner. The spec works around this by
#   intercepting the deploy step's WorkerJobService.enqueue_job dispatch and
#   merging in the just-provisioned `node_instance_id` before invoking the
#   runner's execute_step!. This documents the gap rather than hides it —
#   look for `# === M3 GAP ===` below.
RSpec.describe "AI-driven provisioning M3 deploy-from-repo smoke", type: :integration do
  include PermissionTestHelpers

  let(:account)        { create(:account) }
  let(:admin)          { user_with_permissions("ai.workflows.create", "ai.workflows.execute", account: account) }
  let(:agent)          { create(:ai_agent, account: account) }
  let(:architecture)   { create(:system_node_architecture, :with_checksums) }
  let(:platform_obj)   { create(:system_node_platform, account: account, node_architecture: architecture) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform_obj) }
  let(:provider)       { create(:system_provider, account: account, provider_type: "local_qemu") }
  let(:region)         { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type)  { create(:system_provider_instance_type, account: account, provider: provider) }

  # Pre-seed the nodejs-runtime role module so PlanComposer's
  # attach_role_module_to_template! can resolve "discord_bot" → "nodejs-runtime"
  # and create a TemplateModule join.
  let!(:nodejs_runtime_module) do
    create(:system_node_module,
           account: account,
           name: "nodejs-runtime",
           node_platform: platform_obj,
           variety: "subscription",
           priority: 60,
           description: "Node.js 20 LTS runtime")
  end

  # Brief shape per task #5 step 3: discord_bot deploy with explicit repo + start.
  let(:fixed_brief) do
    {
      "intent" => "Deploy a Discord bot from a Git repo",
      "use_case" => "discord_bot",
      "scale" => { "initial" => 1, "target" => 1, "growth_profile" => "flat" },
      "regions" => ["us-east-1"],
      "compliance" => [],
      "budget_cap_usd_monthly" => 25.0,
      "latency_targets_ms" => { "p99" => 500 },
      "data_residency" => [],
      "preferred_provider" => "local_qemu",
      # M3 Run My Code fields:
      "repo_url" => "https://github.com/example/discord-rss-bot.git",
      "branch" => "main",
      "start_command" => "node index.js"
    }
  end

  # Captures the runner instance so the WorkerJobService stub can route step
  # job dispatches back into it (mirrors M0 pattern).
  let(:runner_holder) { { runner: nil } }

  # Tracks the just-provisioned node_instance — used by the M3 gap workaround
  # to thread node_instance_id into the deploy step's inputs at dispatch time.
  let(:provisioned_holder) { { node_instance: nil } }

  before do
    account
    agent
    load Rails.root.join("../extensions/system/server/db/seeds/system_provisioning_mission_template.rb")

    System::Providers::LocalQemuProvider.runner = System::Providers::LocalQemu::RecorderRunner.new

    # === Stub seam 1: IntentCaptureService.capture → fixed brief ===
    allow_any_instance_of(Ai::Provisioning::IntentCaptureService).to receive(:capture)
      .and_return(brief: fixed_brief, missing_fields: [])

    # === Stub seam 2: GoalDecompositionService#decompose → real GoalPlan ===
    # ONE provision_full_stack step (count=1). PlanComposer.compose! appends
    # the deploy_app_code step automatically because brief["repo_url"] is set.
    allow_any_instance_of(Ai::Autonomy::GoalDecompositionService).to receive(:decompose) do |_svc, goal|
      plan = Ai::GoalPlan.create!(
        account: account, goal: goal, agent: agent,
        status: "draft", version: 1
      )
      plan.steps.create!(
        step_number: 1,
        step_type: "agent_execution", # rewritten to provisioning_skill by composer
        description: "Provision 1 instance for the discord bot",
        dependencies: [],
        execution_config: {
          "skill" => "provision_full_stack",
          "inputs" => {
            "template_id" => template.id,
            "count" => 1,
            "provider_region_id" => region.id,
            "provider_instance_type_id" => instance_type.id
          },
          "on_failure" => "rollback"
        }
      )
      plan
    end

    # === Stub seam 3: WorkerJobService.enqueue_job ===
    # Phase jobs are no-ops; AiProvisioningStepJob cascades into runner.execute_step!.
    #
    # === M3 GAP === Before invoking execute_step! for the deploy_app_code
    # step, merge the provisioned node_instance_id into its execution_config
    # inputs. This simulates the runtime output→input threading that
    # SkillCompositionRunner does NOT yet implement (see header).
    allow(WorkerJobService).to receive(:enqueue_job) do |*positional, **kwargs|
      klass = positional.first
      if klass == "AiProvisioningStepJob" && runner_holder[:runner]
        args_hash = kwargs[:args]
        args_hash = args_hash.first if args_hash.is_a?(Array)
        step_id = args_hash.is_a?(Hash) ? (args_hash[:step_id] || args_hash["step_id"]) : nil
        step = ::Ai::GoalPlanStep.find_by(id: step_id) if step_id

        if step && step.execution_config["skill"] == "deploy_app_code" && provisioned_holder[:node_instance]
          merged_inputs = (step.execution_config["inputs"] || {}).merge(
            "node_instance_id" => provisioned_holder[:node_instance].id
          )
          step.update!(execution_config: step.execution_config.merge("inputs" => merged_inputs))
          step.reload
        end

        runner_holder[:runner].execute_step!(step) if step
      end
      true
    end

    # === Stub seam 4: ProvisioningService.provision_instance → real NodeInstance ===
    allow(System::ProvisioningService).to receive(:provision_instance) do |*_positional, **kwargs|
      node = kwargs[:node]
      ni = ::System::NodeInstance.create!(
        name: "deploy-#{node.name}-#{SecureRandom.hex(2)}",
        node: node,
        variety: "cloud",
        status: "pending",
        provider_region_id: kwargs[:provider_region_id],
        provider_instance_type_id: kwargs[:provider_instance_type_id]
      )
      provisioned_holder[:node_instance] = ni # captured for the M3 gap workaround
      System::Runtime::Result.ok(data: { instance: ni, cloud_instance_id: "ci-#{ni.id[0..7]}" })
    end

    # === Stub seam 5: System::CodeDeployService.call → success ===
    # Per task #5 step 7. Use stub_const so the executor resolves to our
    # double rather than the real Slice A class.
    code_deploy_double = double("System::CodeDeployService")
    allow(code_deploy_double).to receive(:call).and_return(
      success: true,
      commit_sha: "abc123",
      public_url: "http://1.2.3.4:3000"
    )
    stub_const("System::CodeDeployService", code_deploy_double)
  end

  after do
    System::Providers::LocalQemuProvider.reset_runner!
  end

  it "drives a discord-bot deploy from intent through deploy_app_code to handoff" do
    # ---------- 1. Mission creation -----------------------------------------
    mission = ::Ai::Mission.create!(
      account: account,
      created_by: admin,
      name: "Smoke: deploy discord bot from repo",
      mission_type: "infrastructure",
      objective: "M3 deploy-from-repo smoke",
      status: "draft"
    )

    expect(mission.mission_template).to be_present
    expect(mission.mission_template.name).to eq("system_provisioning")

    orchestrator = ::Ai::Missions::OrchestratorService.new(mission: mission)

    # ---------- 2. capture_intent -------------------------------------------
    orchestrator.start!
    expect(mission.reload.current_phase).to eq("capture_intent")

    capture_result = ::Ai::Provisioning::IntentCaptureService.new(account: account, user: admin)
                                                             .capture(natural_language: "Deploy github.com/example/discord-rss-bot main, run `node index.js`")
    expect(capture_result[:brief]).to include("repo_url", "branch", "start_command", "use_case")
    expect(capture_result[:brief]["use_case"]).to eq("discord_bot")
    expect(capture_result[:brief]["repo_url"]).to eq("https://github.com/example/discord-rss-bot.git")
    expect(capture_result[:brief]["start_command"]).to eq("node index.js")
    expect(capture_result[:missing_fields]).to be_empty

    mission.update!(configuration: mission.configuration.merge("brief" => capture_result[:brief]))

    # ---------- 3. compose_plan → 2 steps (provision + deploy) -------------
    orchestrator.advance!(result: { brief_captured: true })
    expect(mission.reload.current_phase).to eq("compose_plan")

    plan = ::Ai::Provisioning::PlanComposerService.new(account: account, mission: mission).compose!
    expect(plan).to be_a(::Ai::GoalPlan)

    steps = plan.steps.reload.order(:step_number).to_a
    expect(steps.size).to eq(2), "expected 2 steps (provision + deploy), got #{steps.size}"

    provision_step = steps.first
    deploy_step    = steps.last

    expect(provision_step.execution_config["skill"]).to eq("provision_full_stack")
    expect(deploy_step.execution_config["skill"]).to eq("deploy_app_code")
    expect(deploy_step.dependencies).to eq([provision_step.step_number]),
           "deploy step must depend on provision step (got #{deploy_step.dependencies.inspect})"

    deploy_inputs = deploy_step.execution_config["inputs"]
    expect(deploy_inputs["repo_url"]).to eq("https://github.com/example/discord-rss-bot.git")
    expect(deploy_inputs["branch"]).to eq("main")
    expect(deploy_inputs["start_command"]).to eq("node index.js")
    expect(deploy_inputs["mission_id"]).to eq(mission.id)

    # The role-module attach side effect (nodejs-runtime → TemplateModule join)
    # is documented as best-effort by PlanComposer (logs and skips when the
    # named module isn't seeded for the account); the integration contract
    # surfaced here is the deploy step's inputs, asserted above. The role-
    # module attach itself is exercised by plan_composer_service_spec.rb.

    mission.update!(configuration: mission.configuration.merge("plan" => { "id" => plan.id }))

    # ---------- 4. review_plan (approval gate) ------------------------------
    orchestrator.advance!(result: { plan_id: plan.id })
    expect(mission.reload.current_phase).to eq("review_plan")
    expect(mission.awaiting_approval?).to be true

    # ---------- 5. Approve → execute ----------------------------------------
    orchestrator.handle_approval!(gate: "review_plan", user: admin, decision: "approved")
    expect(mission.reload.current_phase).to eq("execute")

    # ---------- 6. Run the runner (cascades through both steps) ------------
    runner = ::Ai::Provisioning::SkillCompositionRunner.new(account: account, mission: mission, plan: plan)
    runner_holder[:runner] = runner
    runner.execute!

    # ---------- 7. Provision assertions -------------------------------------
    expect(System::ProvisioningService).to have_received(:provision_instance).at_least(:once)
    expect(provisioned_holder[:node_instance]).to be_present
    instance = provisioned_holder[:node_instance]

    plan.steps.reload.each do |step|
      expect(step.status).to eq("completed"),
             "step #{step.step_number} (#{step.execution_config['skill']}) status was #{step.status}"
    end

    # ---------- 8. Deploy assertions ----------------------------------------
    deployments = ::Ai::ProvisioningCodeDeployment.where(mission_id: mission.id).reload
    expect(deployments.count).to eq(1), "expected exactly 1 ProvisioningCodeDeployment row for the mission"
    deployment = deployments.first
    expect(deployment.status).to eq("running")
    expect(deployment.commit_sha).to eq("abc123")
    expect(deployment.public_url).to eq("http://1.2.3.4:3000")
    expect(deployment.repo_url).to eq("https://github.com/example/discord-rss-bot.git")
    expect(deployment.branch).to eq("main")
    expect(deployment.node_instance_id).to eq(instance.id)
    expect(deployment.deployed_at).to be_present

    # Capture provisioned-resource ids on the mission (the AiProvisioningExecuteJob
    # would do this in production; we do it inline since that job is stubbed).
    mission.update!(
      configuration: mission.configuration.deep_merge(
        "provisioned_resources" => {
          "node_instance_ids" => [instance.id],
          "deployment_ids" => [deployment.id]
        }
      )
    )

    # ---------- 9. verify ---------------------------------------------------
    orchestrator.advance!(result: { provisioned_count: 1, deployment_count: 1 })
    expect(mission.reload.current_phase).to eq("verify")

    # ---------- 10. handoff (approval gate) --------------------------------
    orchestrator.advance!(result: { slo_targets_met: true, deploy_succeeded: true })
    expect(mission.reload.current_phase).to eq("handoff")
    expect(mission.awaiting_approval?).to be true

    # ---------- 11. Approval at handoff → adapting -------------------------
    orchestrator.handle_approval!(gate: "handoff", user: admin, decision: "approved")
    expect(mission.reload.current_phase).to eq("adapting")
    expect(mission.status).to eq("active")
    expect(mission.configuration.dig("provisioned_resources", "deployment_ids")).to eq([deployment.id])
  end
end
