# frozen_string_literal: true

require "rails_helper"

# HIER-P2B-ENG — the four release verbs are approval-gated on the CORE
# `engineering` policy set the Release Manager owns:
#
#   system_dispatch_module_build_batch -> release.build_dispatch   (auto_approve)
#   system_promote_module_version      -> release.promote          (require_approval)
#   system_rollback_module_version     -> release.rollback         (require_approval)
#   system_deploy_platform             -> release.deploy_platform  (require_approval)
#
# Same shape as the disk-image verbs (HIER-P2H): the generic replay executor
# re-invokes the action as the ORIGINAL principal on approval, the action body
# stays the single author of the write, and each gate context resolves the
# target under the account and applies the verb's own admission rule BEFORE
# parking — an unknown, foreign or inadmissible target keeps the inline error
# the verb always gave. The rollback context PINS the auto-selected target so
# the operator approves the version the card names.
#
# The categories are CORE (Ai::InterventionPolicy::STATIC_CATEGORIES) and the
# rows are written by db/seeds/ai_engineering_agents_seed.rb in core; this spec
# mints them in the seed's shape rather than loading the core seed chain.
#
# THE ORACLE IS THE ROW: every gated example reads the module / version /
# deployment back, and the auto_approve and replay examples prove the verbs
# still write, so "gated" cannot be satisfied by a verb that refuses everything.
RSpec.describe "SystemFleetTool release verb gating (HIER-P2B-ENG)" do
  let(:account) { create(:account) }
  # system.nodes.read is the tool floor Ai::Executors::DeferredToolCall
  # re-asks for on replay: for an AGENT principal BaseTool.permitted? answers
  # "any user in the account holds it", so the account needs one such user.
  let!(:operator) { create(:user, account: account, permissions: %w[system.nodes.read]) }
  let(:release_manager) do
    create(:ai_agent, account: account, name: "Release Manager", agent_type: "monitor", source_key: "release-manager")
  end
  # `internal: true` mirrors the in-process bridge the platform executor uses;
  # the AGENT is what the policy resolution keys on, and it rides on the
  # principal descriptor so the replay rebuilds the same caller.
  let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, agent: release_manager, internal: true) }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:category_row) { create(:system_node_module_category, account: account) }
  let!(:node_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category_row, name: "runtime-go")
  end

  def version_with_digest(number, digest: "sha256:#{'a' * 64}", size: 12_345_000)
    create(:system_node_module_version, node_module: node_module, version_number: number,
           artifacts: { "erofs" => { "oci_digest" => digest, "size" => size, "oci_ref" => "ref#{number}" } })
  end

  def seed_release_rows!(overrides = {})
    verbs = {
      "release.build_dispatch"  => "auto_approve",
      "release.promote"         => "require_approval",
      "release.rollback"        => "require_approval",
      "release.deploy_platform" => "require_approval"
    }.merge(overrides)
    verbs.each do |category, verb|
      Ai::InterventionPolicy.create!(
        account: account, scope: "agent", ai_agent_id: release_manager.id, action_category: category,
        policy: verb, priority: 10, is_active: true, conditions: {}, preferred_channels: %w[notification]
      )
    end
  end

  def trust!(tier)
    create(:ai_agent_trust_score, tier, account: account, agent: release_manager)
  end

  def pending_ops
    Ai::DeferredOperation.where(account_id: account.id, status: "pending")
  end

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest).with_indifferent_access)
  end

  def approve_and_replay!(operation)
    operation.update!(status: "approved")
    operation.execute_now!
    operation.reload
  end

  shared_examples "a fully armed release gate" do |action, category|
    it "arms #{action} with the full quartet on the generic replay executor under #{category}" do
      declaration = Ai::Tools::SystemFleetTool.declared_action(action)

      expect(declaration).to be_present
      aggregate_failures do
        expect(declaration[:mutating]).to be(true)
        expect(declaration[:action_category]).to eq(category)
        expect(declaration[:executor_class]).to eq("Ai::Executors::DeferredToolCall")
        expect(declaration[:gate_context]).to be_present
        expect(declaration[:on_proceed]).to be_present
      end
    end

    it "gates on a CORE category (the engineering policy set), registered so the Autonomy modal can save a row" do
      expect(Ai::InterventionPolicy::STATIC_CATEGORIES).to include(category)
      expect(Ai::InterventionPolicy.category_registered?(category)).to be(true)
    end

    it "announces the gate in the description an agent reads" do
      description = Ai::Tools::SystemFleetTool.action_definitions[action][:description]

      expect(description).to include(category)
      expect(description).to match(/pending/i)
      expect(description).to include("when policy requires approval")
    end
  end

  # ---------------------------------------------------------------------------
  describe "system_promote_module_version" do
    include_examples "a fully armed release gate", "system_promote_module_version", "release.promote"

    let!(:version) { version_with_digest(1) }

    before { seed_release_rows! }

    it "parks the promotion: state unchanged, one pending operation anchored to the version" do
      trust!(:monitored)

      result = call("system_promote_module_version", module_version_id: version.id, target_state: "staging")

      expect(result[:success]).to be(true)
      expect(result[:data][:pending]).to be(true)
      expect(result[:data][:action_category]).to eq("release.promote")
      expect(version.reload.promotion_state).to eq("built")
      expect(pending_ops.count).to eq(1)
      expect(pending_ops.first.source_id).to eq(version.id)
    end

    it "keeps parking at AUTONOMOUS trust — the release rows carry no trust unlock" do
      trust!(:autonomous)

      result = call("system_promote_module_version", module_version_id: version.id, target_state: "staging")

      expect(result[:data][:pending]).to be(true)
      expect(version.reload.promotion_state).to eq("built")
    end

    it "promotes on approval, replayed as the original principal" do
      trust!(:monitored)
      call("system_promote_module_version", module_version_id: version.id, target_state: "staging")

      operation = approve_and_replay!(pending_ops.first)

      expect(operation.status).to eq("completed")
      expect(version.reload.promotion_state).to eq("staging")
    end

    it "keeps the inline error for a foreign or unknown version and parks nothing" do
      trust!(:monitored)
      foreign = create(:system_node_module_version, node_module: create(:system_node_module, account: create(:account)))

      [ foreign.id, SecureRandom.uuid ].each do |id|
        result = call("system_promote_module_version", module_version_id: id, target_state: "staging")
        expect(result[:success]).to be(false)
      end
      expect(pending_ops).to be_empty
    end

    it "keeps the inline error for an illegal transition and parks nothing" do
      trust!(:monitored)

      result = call("system_promote_module_version", module_version_id: version.id, target_state: "live")

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("cannot transition from built to live")
      expect(pending_ops).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  describe "system_rollback_module_version" do
    include_examples "a fully armed release gate", "system_rollback_module_version", "release.rollback"

    let!(:good) { version_with_digest(1) }
    let!(:bad)  { version_with_digest(2, size: 1_024) }

    before do
      node_module.promote_to_version!(bad)
      seed_release_rows!
      trust!(:monitored)
    end

    it "parks the rollback and PINS the auto-selected target into the replayed params" do
      result = call("system_rollback_module_version", module_id: node_module.id)

      expect(result[:data][:pending]).to be(true)
      expect(result[:data][:action_category]).to eq("release.rollback")
      expect(node_module.reload.current_version_id).to eq(bad.id)
      operation = pending_ops.first
      expect(operation.params.dig("tool_params", "version_id")).to eq(good.id)
      expect(operation.source_id).to eq(node_module.id)
    end

    it "rolls back on approval to the version the card named" do
      call("system_rollback_module_version", module_id: node_module.id)

      operation = approve_and_replay!(pending_ops.first)

      expect(operation.status).to eq("completed")
      expect(node_module.reload.current_version_id).to eq(good.id)
    end

    it "keeps the inline refusals (no usable target, foreign version, unknown module) and parks nothing" do
      # `other` holds ONE version and it has no mountable artifact: a foreign
      # target for our module, and no usable rollback target of its own.
      other = create(:system_node_module, account: account, node_platform: platform, category: category_row, name: "gitleaks")
      foreign_version = create(:system_node_module_version, node_module: other, artifacts: {})

      foreign = call("system_rollback_module_version", module_id: node_module.id, version_id: foreign_version.id)
      expect(foreign[:success]).to be(false)
      expect(foreign[:error]).to include("belongs to a different module")
      expect(call("system_rollback_module_version", module_id: SecureRandom.uuid)[:success]).to be(false)
      unusable = call("system_rollback_module_version", module_id: other.id)
      expect(unusable[:success]).to be(false)
      expect(unusable[:error]).to include("No usable rollback target")
      expect(pending_ops).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  describe "system_dispatch_module_build_batch" do
    include_examples "a fully armed release gate", "system_dispatch_module_build_batch", "release.build_dispatch"

    def plan_result(entries, excluded: [])
      ::System::ModuleBuildPlannerService::PlanResult.new(entries: entries, excluded: excluded)
    end

    before do
      seed_release_rows!
      trust!(:monitored)
      allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
        .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ]))
      allow(::System::NativeModuleBuildOrchestrator).to receive(:dispatch!).and_return(
        System::NativeModuleBuildOrchestrator::Result.new(ok?: true, dispatched: 1, queued: 0, succeeded: 0, retried: 0, failed: 0)
      )
    end

    it "proceeds under the seeded auto_approve row with the tool's own envelope (the executor replays inline)" do
      result = call("system_dispatch_module_build_batch", base_sha: "base0000", head_sha: "headsha1234567")

      expect(result[:success]).to be(true)
      expect(result[:data][:pending]).to be_nil
      expect(result[:data][:dispatched]).to eq(1)
      expect(System::ModuleBuildBatch.where(account: account).count).to eq(1)
      expect(Ai::DeferredOperation.where(account_id: account.id).pick(:status)).to eq("completed")
    end

    it "parks when an operator tightens the row to require_approval: no batch, no dispatch" do
      Ai::InterventionPolicy.where(account: account, action_category: "release.build_dispatch").update_all(policy: "require_approval")

      result = call("system_dispatch_module_build_batch", base_sha: "base0000", head_sha: "headsha1234567")

      expect(result[:data][:pending]).to be(true)
      expect(System::ModuleBuildBatch.where(account: account)).to be_empty
      expect(::System::NativeModuleBuildOrchestrator).not_to have_received(:dispatch!)
    end

    it "keeps the inline error for a missing sha and parks nothing" do
      result = call("system_dispatch_module_build_batch", base_sha: "", head_sha: "h")

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("base_sha and head_sha are required")
      expect(Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  describe "system_deploy_platform" do
    include_examples "a fully armed release gate", "system_deploy_platform", "release.deploy_platform"

    # A USER principal is re-checked against the tool floor on replay.
    let(:deploy_user) { create(:user, account: account, permissions: %w[system.nodes.read system.platform.deploy]) }
    let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, user: deploy_user, agent: release_manager, internal: true) }
    let!(:deploy_template) { create(:system_node_template, account: account, name: "powernode-hub-spec") }

    before do
      seed_release_rows!
      provisioned = instance_double("ProvisionResult", success?: true, data: { instance: nil })
      allow(::System::ProvisioningService).to receive(:provision_instance).and_return(provisioned)
    end

    it "parks a standalone deploy: nothing provisioned, one pending operation" do
      trust!(:monitored)

      result = call("system_deploy_platform", mode: "standalone", name: "child-platform", template_slug: deploy_template.name)

      expect(result[:data][:pending]).to be(true)
      expect(result[:data][:action_category]).to eq("release.deploy_platform")
      expect(::System::ProvisioningService).not_to have_received(:provision_instance)
      expect(pending_ops.count).to eq(1)
    end

    it "ALWAYS parks a deploy — trust never unlocks it (the control plane's own deployment included)" do
      trust!(:autonomous)

      result = call("system_deploy_platform", mode: "standalone", name: "child-platform", template_slug: deploy_template.name)

      expect(result[:data][:pending]).to be(true)
      expect(::System::ProvisioningService).not_to have_received(:provision_instance)
    end

    it "deploys on approval, replayed as the original principal" do
      trust!(:monitored)
      call("system_deploy_platform", mode: "standalone", name: "child-platform", template_slug: deploy_template.name)

      operation = approve_and_replay!(pending_ops.first)

      expect(operation.status).to eq("completed")
      expect(::System::ProvisioningService).to have_received(:provision_instance)
    end

    it "returns the wizard card inline for a mode-less call — the read arm never meets the gate" do
      trust!(:monitored)
      expect(Ai::AutonomyGate).not_to receive(:evaluate)

      result = call("system_deploy_platform")

      expect(result[:success]).to be(true)
      expect(result[:data][:card][:kind]).to eq("platform_deployment_wizard")
      expect(Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end

    it "keeps the federated refusal inline (the token cannot be delivered here) and parks nothing" do
      trust!(:monitored)

      result = call("system_deploy_platform", mode: " Federated ", name: "child", template_slug: deploy_template.name,
                                              parent_url: "https://parent.example.test", spawn_mode: "managed_child")

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("MCP tool surface")
      expect(result[:error]).to include("/api/v1/system/platform/deployments")
      expect(Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end

    it "keeps the inline error for a nameless deploy and parks nothing" do
      trust!(:monitored)

      result = call("system_deploy_platform", mode: "standalone")

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("name")
      expect(Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end
  end
end
