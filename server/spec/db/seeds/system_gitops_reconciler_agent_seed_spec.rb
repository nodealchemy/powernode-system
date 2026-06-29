# frozen_string_literal: true

require "rails_helper"

# Pins the GitOps Reconciler agent seed + its wiring. Before this agent
# existed, System::Gitops::Reconciler#gitops_agent_id attributed every GitOps
# proposal to an ARBITRARY account agent (Ai::Agent.where(account:).first).
# These specs hold the contract that:
#   1. the seed creates the named agent with the expected posture, and
#   2. the reconciler resolves IT (not an arbitrary agent) as the author, and
#   3. the autonomous drift signal is wired through the DecisionEngine to a
#      Fleet-Autonomy-owned policy (the sensor gates as Fleet Autonomy).
RSpec.describe "system_gitops_reconciler_agent seed" do
  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  # GitOps Reconciler is a GLOBAL (platform-provided) agent (account_id nil).
  let(:agent) { Ai::Agent.global.find_by(name: "GitOps Reconciler") }

  describe "the seeded agent" do
    before { load_seed!("system_gitops_reconciler_agent.rb") }

    it "creates a GLOBAL monitor agent named 'GitOps Reconciler'" do
      expect(agent).to be_present
      expect(agent.account_id).to be_nil
      expect(agent.is_system).to be true
      expect(agent.source_key).to eq("gitops-reconciler")
      expect(agent.agent_type).to eq("monitor")
      expect(agent.status).to eq("active")
    end

    it "carries a non-empty system_prompt" do
      expect(agent.system_prompt.to_s.strip).not_to be_empty
      expect(agent.system_prompt).to match(/GitOps Reconciler/)
    end

    it "requests a reasoning-tier model via model_requirements (no hardcoded model id)" do
      requirements = agent.mcp_metadata.dig("model_config", "model_requirements")
      expect(requirements).to eq("tier" => "reasoning")
      # No pinned/hardcoded model id — resolution is left to AgentModelSelector.
      expect(agent.mcp_metadata.dig("model_config", "model")).to be_blank
    end

    it "bootstraps a monitored trust score at 0.72" do
      score = Ai::AgentTrustScore.find_by(agent_id: agent.id)
      expect(score).to be_present
      expect(score.tier).to eq("monitored")
      expect(score.overall_score.to_f.round(2)).to eq(0.72)
    end

    it "owns the operator-initiated system.gitops_* policies" do
      categories = Ai::InterventionPolicy
        .where(account: account, ai_agent_id: agent.id, scope: "agent", is_active: true)
        .pluck(:action_category, :policy).to_h

      expect(categories).to eq(
        "system.gitops_apply_proposal"      => "require_approval",
        "system.gitops_register_repository" => "require_approval",
        "system.gitops_sync_repository"     => "auto_approve"
      )
    end

    it "does NOT own the autonomous drift-remediation policy (that gates as Fleet Autonomy)" do
      expect(
        Ai::InterventionPolicy.exists?(
          account: account, ai_agent_id: agent.id,
          action_category: "system.gitops_drift_remediate"
        )
      ).to be false
    end

    it "creates its own approval chain" do
      chain = Ai::ApprovalChain.find_by(account: account, name: "GitOps Reconciler Actions")
      expect(chain).to be_present
      expect(chain.status).to eq("active")
    end

    it "is idempotent across re-runs (no duplicate global row)" do
      expect { load_seed!("system_gitops_reconciler_agent.rb") }
        .not_to change { Ai::Agent.global.where(name: "GitOps Reconciler").count }.from(1)
    end
  end

  describe "reconciler proposal attribution" do
    before { load_seed!("system_gitops_reconciler_agent.rb") }

    it "attributes GitOps proposals to the (global) GitOps Reconciler, not an arbitrary one" do
      # An earlier-created account agent would have won the old fallback ordering.
      create(:ai_agent, account: account, name: "Some Other Agent", agent_type: "assistant")
      repo = create(:system_gitops_repository, account: account)

      reconciler = System::Gitops::Reconciler.new(repository: repo)
      expect(reconciler.send(:gitops_agent_id)).to eq(agent.id) # resolve_for finds the global default
    end
  end

  describe "DecisionEngine wiring for the autonomous drift signal" do
    it "binds system.gitops.drift_detected to a notify-only gitops_drift_remediate gate" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.gitops.drift_detected"]
      expect(binding).to be_present
      expect(binding[:action_category]).to eq("system.gitops_drift_remediate")
      expect(binding[:skill]).to be_nil # notification gate; the reconciler does the applying
    end
  end

  describe "the autonomous policy on Fleet Autonomy" do
    it "places system.gitops_drift_remediate on the Fleet Autonomy agent" do
      load_seed!("fleet_autonomy_agent.rb")
      fleet = Ai::Agent.global.find_by(name: "Fleet Autonomy")
      expect(fleet).to be_present

      policy = Ai::InterventionPolicy.find_by(
        account: account, ai_agent_id: fleet.id, scope: "agent",
        action_category: "system.gitops_drift_remediate"
      )
      expect(policy).to be_present
      expect(policy.policy).to eq("notify_and_proceed")
    end
  end
end
