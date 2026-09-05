# frozen_string_literal: true

require "rails_helper"

# HIER-P2E — the Supply Chain Manager as seeded data. HIER-P2DECL declared the
# identity ("supply-chain-manager"), its policy set
# (SUPPLY_CHAIN_MANAGER_POLICIES), the package_drift_pressure binding's owner
# and its seat under System Concierge; this file pins the wave-2 seed that
# makes the declaration real:
#   1. the agent is a GLOBAL canonical (account_id nil, is_system, source_key),
#      never adopted from a stray account row;
#   2. it hangs under System Concierge with one seed edge + the P1 leaf
#      delegation once the hierarchy seed runs;
#   3. its policy rows are written by PolicyReconciler (the seed writes NONE —
#      the set moved off Fleet Autonomy, and the reconciler re-homes an
#      established install's tuned rows in place; a seed upsert would leave the
#      old owner's row behind as a duplicate the reconciler refuses to touch);
#   4. the executors in its domain bind to it, and the CVE Responder keeps
#      package_module_refresh (the CVE lane invokes it directly).
RSpec.describe "system_supply_chain_manager_agent seed" do
  SUPPLY_CHAIN_SKILL_SLUGS = %w[
    system-package-repository-sync
    system-package-module-create
    system-package-module-refresh
    system-architecture-propose
    system-architecture-create
    system-architecture-update
    system-architecture-delete
    system-suggest-architectures-for-fleet
  ].freeze

  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  let(:agent)    { Ai::Agent.global.find_by(name: "Supply Chain Manager") }
  let(:declared) { System::Governance::PolicyDeclarations::SUPPLY_CHAIN_MANAGER_POLICIES }

  def policy_rows(for_agent)
    Ai::InterventionPolicy
      .where(account: account, ai_agent_id: for_agent.id, scope: "agent", is_active: true)
      .pluck(:action_category, :policy).to_h
  end

  describe "the seeded agent" do
    before { load_seed!("system_supply_chain_manager_agent.rb") }

    it "creates a GLOBAL canonical monitor agent with the declared identity" do
      expect(agent).to be_present
      expect(agent.account_id).to be_nil
      expect(agent.is_system).to be true
      expect(agent.source_key).to eq("supply-chain-manager")
      expect(agent.slug).to eq("supply-chain-manager")
      expect(agent.agent_type).to eq("monitor")
      expect(agent.status).to eq("active")

      identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("supply-chain-manager")
      expect(identity).to eq(name: agent.name, agent_type: agent.agent_type)
    end

    it "carries a ROUTING description (trigger + hand-offs) within the export's 400-char budget" do
      expect(agent.description.length).to be <= Ai::ClaudeExport::RoutingDescription::MAX_CHARS
      expect(agent.description).to match(/Use when/)
      expect(agent.description).to match(/Do not use for/)
      expect(agent.description).to include("CVE Responder")
      expect(agent.description).to include("Disk Image Manager")
      expect(agent.description).to include("Fleet Autonomy")
    end

    it "carries a persona prompt naming its policy verbs, the CVE-lane refresh path and its hand-offs" do
      prompt = agent.system_prompt.to_s
      expect(prompt).to match(/Supply Chain Manager/)
      declared.each_key do |category|
        expect(prompt).to include(category), "system prompt should name the policy verb #{category}"
      end
      expect(prompt).to include("CVE Responder")
      expect(prompt).to include("Disk Image Manager")
      expect(prompt).to include("Fleet Autonomy")
      expect(prompt).to match(/SBOM/)
    end

    it "requests a reasoning-tier model via model_requirements (no hardcoded model id)" do
      expect(agent.mcp_metadata.dig("model_config", "model_requirements")).to eq("tier" => "reasoning")
      expect(agent.mcp_metadata.dig("model_config", "model")).to be_blank
    end

    it "scopes tool access to the supply-chain families — every family resolves, and the export is scoped" do
      families = agent.mcp_metadata.dig("tool_access", "tool_families")
      expect(families).to be_an(Array).and be_present

      registry = Ai::ClaudeExport::ToolAllowlist::Registry.snapshot
      unresolved = families.reject do |family|
        registry.action_names.any? { |name| name == family || name.start_with?("#{family}_") }
      end
      expect(unresolved).to be_empty, "tool families matching no registered action: #{unresolved.inspect}"

      allowlist = Ai::ClaudeExport::ToolAllowlist.for(agent, registry: registry)
      expect(allowlist).not_to be_nil # nil = unscoped (inherit everything)
      actions = allowlist.grep(/\Amcp__powernode__platform_/).map { |t| t.delete_prefix("mcp__powernode__platform_") }

      expect(actions).to include(
        "system_list_package_repositories", "system_sync_package_repository", "system_search_packages",
        "system_create_module_from_package", "system_refresh_package_module",
        "system_list_architectures", "system_propose_architecture", "system_create_architecture",
        "system_list_modules", "system_get_module", "system_get_cve", "system_get_cve_exposure"
      )
      expect(actions).not_to include(
        "system_sdwan_list_networks", "system_create_cve", "system_delete_module",
        "system_promote_module_version", "system_deploy_platform", "system_delete_package_repository"
      )
    end

    it "bootstraps a monitored trust score" do
      score = Ai::AgentTrustScore.find_by(agent_id: agent.id)
      expect(score).to be_present
      expect(score.tier).to eq("monitored")
      expect(score.overall_score.to_f.round(2)).to eq(0.70)
    end

    it "creates its own approval chain that rejects on timeout" do
      chain = Ai::ApprovalChain.find_by(account: account, name: "Supply Chain Manager Actions")
      expect(chain).to be_present
      expect(chain.trigger_type).to eq("autonomy_action")
      expect(chain.status).to eq("active")
      expect(chain.timeout_action).to eq("reject")
      expect(chain.timeout_hours).to be > 0
    end

    it "writes NO policy row itself — PolicyReconciler owns the moved set" do
      expect(Ai::InterventionPolicy.where(ai_agent_id: agent.id)).to be_empty
    end

    it "is idempotent across re-runs (no duplicate global row, chain or trust score)" do
      expect { load_seed!("system_supply_chain_manager_agent.rb") }
        .not_to change { [ Ai::Agent.global.where(name: "Supply Chain Manager").count,
                           Ai::ApprovalChain.where(name: "Supply Chain Manager Actions").count,
                           Ai::AgentTrustScore.where(agent_id: agent.id).count ] }
        .from([ 1, 1, 1 ])
    end
  end

  describe "the canonical rule" do
    it "refuses to adopt a stray ACCOUNT-scoped agent of the same name and type" do
      create(:ai_agent, account: account, name: "Supply Chain Manager", agent_type: "monitor")

      expect { load_seed!("system_supply_chain_manager_agent.rb") }
        .to raise_error(System::Seeds::AgentSetupHelpers::CanonicalAgentConflict, /Supply Chain Manager/)
      expect(agent).to be_nil
    end
  end

  describe "under System Concierge (HIER-P1 seat)" do
    before do
      load_seed!("system_concierge_agent.rb")
      load_seed!("system_supply_chain_manager_agent.rb")
      load_seed!("system_agent_hierarchy.rb")
    end

    let(:root) { Ai::Agent.global.find_by!(source_key: "system-concierge") }

    it "is attached with exactly one active seed edge and the conservative depth-2 leaf delegation" do
      edges = Ai::AgentLineage.for_child(agent.id).active
      expect(edges.pluck(:parent_agent_id)).to eq([ root.id ])
      expect(edges.first.spawn_reason).to eq("seed")
      expect(agent.reload.parent_agent_id).to eq(root.id)

      policy = Ai::DelegationPolicy.resolve_for(agent_id: agent.id, account_id: account.id)
      expect(policy).to be_present
      expect(policy.inheritance_policy).to eq("conservative")
      expect(policy.max_depth).to eq(2)
      expect(policy.allowed_delegate_types).to eq([])
    end

    it "is no longer reported as an absent child by the hierarchy drift report" do
      report = System::Governance::HierarchyReconciler.new(account: account).drift
      expect(report.skipped).not_to include("supply-chain-manager(agent absent)")
      expect(report.present).to include("system-concierge/supply-chain-manager")
      expect(report.missing_edges).to be_empty
      expect(report.missing_policies).to be_empty
    end
  end

  describe "PolicyReconciler" do
    let(:logger) { Logger.new(IO::NULL) }

    # HIER-P2I: the reconciler writes against the account's ACTING principal
    # for a canonical — its clone, minted on first use — not the canonical.
    def principal_for(agent_key)
      System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: agent_key)
    end

    it "no longer skips the set, and writes every declared category on a fresh install" do
      load_seed!("system_supply_chain_manager_agent.rb")

      result = System::Governance::PolicyReconciler.new(account: account, logger: logger).reconcile!
      expect(result.skipped_sets).not_to include("supply-chain-manager(agent absent)")
      principal = principal_for("supply-chain-manager")
      expect(principal.cloned_from_id).to eq(agent.id)
      expect(policy_rows(principal)).to eq(declared)

      report = System::Governance::PolicyReconciler.new(account: account, logger: logger).drift
      expect(report.missing.select { |m| m.set_key == "supply-chain-manager" }).to be_empty
    end

    it "re-homes an established install's tuned row off Fleet Autonomy in place (same id, verb kept)" do
      load_seed!("fleet_autonomy_agent.rb")
      fleet = Ai::Agent.global.find_by!(name: "Fleet Autonomy")
      tuned = Ai::InterventionPolicy.create!(
        account: account, scope: "agent", ai_agent_id: fleet.id, user_id: nil,
        action_category: "system.package_module.create", policy: "notify_and_proceed",
        priority: 42, is_active: true, conditions: { "trust_tier_minimum" => "trusted" },
        preferred_channels: %w[notification]
      )

      load_seed!("system_supply_chain_manager_agent.rb")
      result = System::Governance::PolicyReconciler.new(account: account, logger: logger).reconcile!

      expect(result.rehomed).to include("supply-chain-manager/system.package_module.create (from Fleet Autonomy)")
      # The tuned row first followed Fleet Autonomy onto its clone
      # (AccountPrincipalResolver#follow_on_moves!), then moved to the Supply
      # Chain Manager's clone: same id, verb and priority kept.
      principal = principal_for("supply-chain-manager")
      expect(tuned.reload.ai_agent_id).to eq(principal.id)
      expect(tuned.policy).to eq("notify_and_proceed")
      expect(tuned.priority).to eq(42)
      expect(policy_rows(fleet)).not_to have_key("system.package_module.create")
      expect(policy_rows(principal_for("fleet-autonomy"))).not_to have_key("system.package_module.create")
      expect(policy_rows(principal).keys).to match_array(declared.keys)
    end
  end

  describe "skill bindings" do
    before(:all) do
      glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
      Dir.glob(glob).each { |f| require_dependency f }
    end

    let(:registry) { System::Ai::Skills::SkillBindings.discover }

    def owners_of(slug)
      registry.select { |e| e[:skill_slug] == slug }.map { |e| e[:agent_key] }
    end

    it "registers every supply-chain executor on the Supply Chain Manager and on Fleet Autonomy no longer" do
      SUPPLY_CHAIN_SKILL_SLUGS.each do |slug|
        owners = owners_of(slug)
        expect(owners).to include("supply-chain-manager"), "#{slug} should bind to Supply Chain Manager (owners=#{owners.inspect})"
        expect(owners).not_to include("fleet-autonomy"), "#{slug} still binds to Fleet Autonomy (owners=#{owners.inspect})"
      end
    end

    it "keeps package_module_refresh reachable from the CVE lane (CVE Responder stays bound)" do
      expect(owners_of("system-package-module-refresh")).to include("cve-responder")
    end

    it "materialises the bindings through system_skill_bindings_seed and drops the Fleet Autonomy rows" do
      silence_warnings do
        %w[system_skills_seed.rb system_provisioning_skills_seed.rb system_dr_skills_seed.rb].each { |f| load_seed!(f) }
      end
      %w[fleet_autonomy_agent.rb system_concierge_agent.rb system_cve_responder_agent.rb
         system_supply_chain_manager_agent.rb].each { |f| load_seed!(f) }

      fleet = Ai::Agent.global.find_by!(name: "Fleet Autonomy")
      cve   = Ai::Agent.global.find_by!(name: "CVE Responder")
      # A stale row from the pre-P2E binding, which the seed must clean up.
      stale_skill = Ai::Skill.find_by!(slug: "system-package-repository-sync")
      Ai::AgentSkill.create!(ai_agent_id: fleet.id, ai_skill_id: stale_skill.id, priority: 1, is_active: true)

      load_seed!("system_skill_bindings_seed.rb")

      bound = Ai::AgentSkill.where(ai_agent_id: agent.id, is_active: true).joins(:skill).pluck("ai_skills.slug")
      expect(bound).to match_array(SUPPLY_CHAIN_SKILL_SLUGS)

      fleet_bound = Ai::AgentSkill.where(ai_agent_id: fleet.id).joins(:skill).pluck("ai_skills.slug")
      expect(fleet_bound & SUPPLY_CHAIN_SKILL_SLUGS).to be_empty

      cve_bound = Ai::AgentSkill.where(ai_agent_id: cve.id).joins(:skill).pluck("ai_skills.slug")
      expect(cve_bound).to include("system-package-module-refresh")
    end
  end
end
