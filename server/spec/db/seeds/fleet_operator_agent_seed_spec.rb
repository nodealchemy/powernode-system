# frozen_string_literal: true

require "rails_helper"

# Skills-first agents, PRE-2: fleet-operator is seeded by THIS extension through
# core's roster registry (core never names it). Shadow mode like core's three:
# inactive on create, tier standard, trust and approval chain CREATE-ONLY, and
# NO intervention-policy row (PolicyReconciler is the single writer).
RSpec.describe "db/seeds/fleet_operator_agent.rb", type: :seed do
  let(:roster) { Ai::Agents::CanonicalRoster }
  let(:seed_file) { Rails.root.join("../extensions/system/server/db/seeds/fleet_operator_agent.rb").cleanpath }
  let(:orchestrator) { Rails.root.join("../extensions/system/server/db/seeds.rb").cleanpath }

  def load_seed!
    silence_warnings do
      original = $stdout
      $stdout = StringIO.new
      load seed_file
    ensure
      $stdout = original
    end
  end

  def fleet_operator = Ai::Agent.global.find_by!(slug: "fleet-operator")

  describe "the registration" do
    it "registers fleet-operator into core's roster, owned by this extension, tier standard" do
      owners = roster.each.to_h { |slug, _spec, owner| [ slug, owner ] }

      expect(owners["fleet-operator"]).to eq("extensions/system")
      expect(roster.fetch("fleet-operator")).to include(tier: "standard", agent_type: "monitor", name: "Fleet Operator")
    end

    it "absorbs the whole System Operations roster (the eleven domain agents; the team's manager is the concierge's)" do
      expect(roster.fetch("fleet-operator")[:absorbs]).to match_array(
        %w[fleet-autonomy sdwan-manager cve-responder disk-image-manager runtime-manager gitops-reconciler
           system-topology-designer topology-designer capacity-manager storage-manager ingress-manager
           supply-chain-manager]
      )
      expect(roster.absorbing("storage-manager")).to eq("fleet-operator")
      expect(roster.absorbing("topology-designer")).to eq("fleet-operator")
    end

    it "absorbs exactly the member slugs of the System Operations template, less its manager" do
      members = %w[infrastructure-generalist fleet-autonomy sdwan-manager cve-responder disk-image-manager runtime-manager
                   gitops-reconciler system-topology-designer capacity-manager storage-manager ingress-manager supply-chain-manager]
      (members - %w[infrastructure-generalist]).each { |slug| expect(roster.absorbing(slug)).to eq("fleet-operator"), slug }
      expect(roster.absorbing("infrastructure-generalist")).to eq("powernode-concierge")
    end

    it "gives it the system domains as its ceiling, a whole-server grant without a code shell, and an assembly charter" do
      spec = roster.fetch("fleet-operator")

      expect(spec[:domains]).to match_array(Ai::Skills::Contract.domains_for("extensions/system"))
      expect(spec[:role]).to include(code: false, shell: false, server_grant: true)
      expect(spec[:charter].lines.reject { |l| l.strip.empty? }.size).to be <= 25
      expect(spec[:charter]).to include("assemble_task", "route_task", "record_agent_execution")
    end

    it "makes every skeleton set the roster's: core's three plus fleet-operator when this extension is loaded" do
      expect(roster.slugs).to match_array(%w[powernode-concierge platform-engineer platform-reviewer fleet-operator])
    end
  end

  describe "seeding" do
    let!(:account) { create(:account, name: "Powernode Admin") }
    let!(:user) { create(:user, account: account, email: "admin@powernode.org") }

    it "creates the global, system, inactive canonical with the roster's text and tier" do
      load_seed!

      expect(fleet_operator).to have_attributes(account_id: nil, is_system: true, source_key: "fleet-operator", status: "inactive",
                                                name: "Fleet Operator", agent_type: "monitor", is_concierge: false,
                                                description: roster.fetch("fleet-operator")[:description],
                                                system_prompt: roster.fetch("fleet-operator")[:charter].strip)
      expect(fleet_operator.mcp_metadata.dig("model_config", "model_requirements", "tier")).to eq("standard")
    end

    it "creates trust (monitored) and the 4h reject-on-timeout chain, on create only" do
      load_seed!
      score = Ai::AgentTrustScore.find_by!(agent_id: fleet_operator.id)
      chain = Ai::ApprovalChain.find_by!(account: account, name: "Fleet Operator Actions")
      expect(score.tier).to eq("monitored")
      expect(chain).to have_attributes(trigger_type: "autonomy_action", timeout_hours: 4, timeout_action: "reject")

      score.update!(tier: "trusted", overall_score: 0.9)
      chain.update!(timeout_hours: 8)
      load_seed!

      expect(score.reload.tier).to eq("trusted")
      expect(chain.reload.timeout_hours).to eq(8)
    end

    it "writes no intervention-policy row" do
      expect { load_seed! }.not_to change(Ai::InterventionPolicy, :count)
    end

    it "is idempotent: a second run changes no row and no column" do
      load_seed!
      snapshot = -> { [ Ai::Agent.global.where(slug: "fleet-operator").pluck(:id, :updated_at, :mcp_metadata), Ai::AgentTrustScore.pluck(:id, :updated_at), Ai::ApprovalChain.pluck(:id, :updated_at) ] }
      before = snapshot.call

      load_seed!

      expect(snapshot.call).to eq(before)
    end

    it "keeps an operator's activation and edited charter on re-seed" do
      load_seed!
      fleet_operator.update!(status: "active", system_prompt: "our own charter")

      load_seed!

      expect(fleet_operator.reload).to have_attributes(status: "active", system_prompt: "our own charter")
    end

    it "is not seeded by core's canonical seed (core iterates only what core registered)" do
      silence_warnings { load Rails.root.join("db", "seeds", "ai_canonical_agents_seed.rb") }

      expect(Ai::Agent.global.where(slug: "fleet-operator")).to be_empty
    end
  end

  it "seeds without any account (a fresh install): the agent row, nothing account-scoped" do
    load_seed!

    expect(fleet_operator.status).to eq("inactive")
    expect(Ai::AgentTrustScore.count).to eq(0)
    expect(Ai::ApprovalChain.count).to eq(0)
  end

  it "is listed in the orchestrator, after the registry-dependent core seeds and before the skill graph sync" do
    listed = File.read(orchestrator)[/SYSTEM_SEED_FILES = %w\[(.*?)\]/m, 1].split

    expect(listed).to include("fleet_operator_agent.rb")
    expect(listed.index("fleet_operator_agent.rb")).to be < listed.index("system_agent_hierarchy.rb")
  end
end
