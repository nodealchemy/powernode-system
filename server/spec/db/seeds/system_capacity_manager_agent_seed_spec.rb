# frozen_string_literal: true

require "rails_helper"

# HIER-P2B — the Capacity Manager as SEEDED DATA. HIER-P2DECL declared the
# agent (identity, policy set, sensor ownership, hierarchy seat) ahead of this
# seed; until it landed, every `owner: "capacity-manager"` binding gated under
# Fleet Autonomy with a `fleet.owner_agent_missing` event and the twenty-two
# declared rows had no agent to land on for a fresh install. These pin:
#   1. the canonical row (global, is_system, source_key, monitor, routing
#      description, reasoning tier, scoped tool families),
#   2. the operational rows the seed writes per account (the trust score, the
#      approval chain) — and NOT the policy set: PolicyReconciler is its single
#      writer (proposal §5 ruling 7, IMP-10e4f6c3bcd2), asserted here against
#      the account's acting principal, project.scale_horizontal's condition
#      override included,
#   3. that PolicyReconciler writes the set rather than skipping it,
#   4. the hierarchy seat + leaf delegation written by system_agent_hierarchy.rb,
#   5. the executor re-binding materialised by system_skill_bindings_seed.rb.
RSpec.describe "system_capacity_manager_agent seed" do
  SEEDS_DIR = Rails.root.join("..", "extensions", "system", "server", "db", "seeds")

  def load_seed!(file)
    silence_warnings { load SEEDS_DIR.join(file) }
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  let(:declarations) { System::Governance::PolicyDeclarations }
  let(:agent) { Ai::Agent.global.find_by(name: "Capacity Manager") }
  let(:principal) { System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: "capacity-manager") }

  def reconcile!
    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!
  end

  describe "the seeded agent" do
    before { load_seed!("system_capacity_manager_agent.rb") }

    it "creates a GLOBAL monitor canonical named 'Capacity Manager' keyed capacity-manager" do
      expect(agent).to be_present
      expect(agent.account_id).to be_nil
      expect(agent.is_system).to be true
      expect(agent.source_key).to eq("capacity-manager")
      expect(agent.agent_type).to eq("monitor")
      expect(agent.status).to eq("active")
      # The Claude Code counterpart is keyed on the slug (RoutableAgents.key),
      # and the skeleton's bootstrap step fetches by it.
      expect(Ai::Routing::RoutableAgents.key(agent)).to eq("capacity-manager")
      expect(Ai::Routing::RoutableAgents.canonical).to include(agent)
    end

    # HIER-P2I: the canonical is a template; what the tick ACTS as is the
    # account's clone of it, so the resolver answers with a row cloned from
    # the seeded agent rather than the seeded agent itself.
    it "matches the declared identity exactly, so AgentResolver resolves the account's clone of it for the fleet tick" do
      identity = declarations::AGENT_IDENTITIES.fetch("capacity-manager")
      expect([ agent.name, agent.agent_type ]).to eq([ identity[:name], identity[:agent_type] ])
      resolved = System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: "capacity-manager")
      expect(resolved.cloned_from_id).to eq(agent.id)
      expect(resolved.account_id).to eq(account.id)
    end

    it "carries a ROUTING description (trigger + exclusion naming the siblings) within the export budget" do
      description = agent.description.to_s
      expect(description.length).to be <= Ai::ClaudeExport::RoutingDescription::MAX_CHARS
      expect(description).to match(/Use when/)
      expect(description).to match(/Do not use for/)
      %w[Fleet\ Autonomy Storage\ Manager Ingress\ Manager Supply\ Chain\ Manager].each do |sibling|
        expect(description).to include(sibling)
      end
    end

    it "carries the capacity-keeper persona prompt with the self-protection rule and the hand-offs" do
      prompt = agent.system_prompt.to_s
      expect(prompt.strip).not_to be_empty
      expect(prompt).to match(/Capacity Manager/)
      expect(prompt).to match(/control plane/i)
      expect(prompt).to match(/never scale in/i)
      expect(prompt).to match(/cordon/i)
      %w[Storage\ Manager Ingress\ Manager Supply\ Chain\ Manager Fleet\ Autonomy].each do |sibling|
        expect(prompt).to include(sibling)
      end
    end

    it "requests a reasoning-tier model via model_requirements (no hardcoded model id)" do
      expect(agent.mcp_metadata.dig("model_config", "model_requirements")).to eq("tier" => "reasoning")
      expect(agent.mcp_metadata.dig("model_config", "model")).to be_blank
    end

    it "scopes tool access to the capacity families only, so the CC allowlist is scoped (never nil)" do
      families = agent.mcp_metadata.dig("tool_access", "tool_families")
      expect(families).to be_an(Array)
      expect(families).not_to be_empty

      allowlist = Ai::ClaudeExport::ToolAllowlist.for(agent)
      expect(allowlist).to be_an(Array) # nil would mean UNSCOPED: every tool inherited

      names = allowlist.map { |t| t.delete_prefix(Ai::ClaudeExport::ToolAllowlist::MCP_PREFIX) }
      %w[
        system_list_instances system_get_instance system_provision_instance system_replace_instance
        system_reap_instance system_cordon_instance system_uncordon_instance system_drain_instance
        system_list_instance_pools system_replenish_instance_pool system_acquire_pooled_instance
        system_platform_resilience system_list_nodes system_list_templates system_list_tasks system_list_volumes
      ].each { |name| expect(names).to include(name), "expected #{name} in the Capacity Manager allowlist" }

      # Bootstrap + self-report verbs always ride along.
      expect(names).to include("get_agent", "get_skill_context", "record_agent_execution")

      # Other domains' verbs must not leak in through a loose family prefix.
      leaked = names.grep(/sdwan|acme|expose_service|package|architecture|gitops|cve|disk_image|docker/)
      expect(leaked).to be_empty, "non-capacity verbs leaked into the allowlist: #{leaked.inspect}"
      expect(names).not_to include("system_deploy_platform", "system_delete_volume", "system_restore_volume_snapshot")
    end

    it "bootstraps a monitored trust score at 0.72" do
      score = Ai::AgentTrustScore.find_by(agent_id: agent.id)
      expect(score).to be_present
      expect(score.tier).to eq("monitored")
      expect(score.overall_score.to_f.round(2)).to eq(0.72)
    end

    it "writes NO policy row itself — PolicyReconciler is the single writer" do
      expect(Ai::InterventionPolicy.where(account: account)).to be_empty
    end

    it "owns exactly CAPACITY_MANAGER_POLICIES at the agent shape once reconciled, with scale_horizontal's window override" do
      reconcile!
      rows = Ai::InterventionPolicy.where(account: account, ai_agent_id: principal.id, scope: "agent", is_active: true)
      expect(rows.pluck(:action_category, :policy).to_h).to eq(declarations::CAPACITY_MANAGER_POLICIES)

      overrides = declarations::PROVISIONING_CONDITION_OVERRIDES
      rows.each do |row|
        expected = overrides.fetch(row.action_category, declarations::DEFAULT_TRUST_CONDITIONS)
        expect(row.conditions).to eq(expected), "#{row.action_category} conditions #{row.conditions.inspect}"
        expect(row.priority).to eq(10)
      end
      expect(rows.find_by(action_category: "project.scale_horizontal").conditions)
        .to include("auto_apply_window" => "watch_policies.auto_scale_max_replicas")
    end

    it "keeps the agent set and the operator twins at separate shapes once reconciled" do
      reconcile!
      twin_keys = declarations::INSTANCE_POOL_OPERATOR_POLICIES.keys +
                  declarations::PLATFORM_SCALING_POLICIES.keys +
                  declarations::INSTANCE_CORDON_OPERATOR_POLICIES.keys
      twins = Ai::InterventionPolicy.where(account: account, ai_agent_id: nil, scope: "global", action_category: twin_keys)
      expect(twins.pluck(:action_category)).to match_array(twin_keys)
      expect(Ai::InterventionPolicy.where(account: account, ai_agent_id: principal.id, scope: "global")).to be_empty
    end

    it "gives PolicyReconciler the whole capacity set to CREATE (not skip, not re-home) on a fresh install" do
      report = System::Governance::PolicyReconciler.new(account: account).drift
      expect(report.skipped_sets.grep(/capacity-manager/)).to be_empty
      capacity_missing = report.missing.select { |row| row.set_key == "capacity-manager" }
      expect(capacity_missing.map(&:action_category)).to match_array(declarations::CAPACITY_MANAGER_POLICIES.keys)
      expect(capacity_missing.select(&:rehome_from)).to be_empty

      result = reconcile!
      expect(result.created_categories.grep(%r{\Acapacity-manager/}).size).to eq(declarations::CAPACITY_MANAGER_POLICIES.size)

      after = System::Governance::PolicyReconciler.new(account: account).drift
      expect(after.missing.select { |row| row.set_key == "capacity-manager" }).to be_empty
      expect(after.present.grep(%r{\Acapacity-manager/}).size).to eq(declarations::CAPACITY_MANAGER_POLICIES.size)
    end

    it "is the declared owner of the sensor-routed capacity bindings" do
      engine = System::Fleet::DecisionEngine
      %w[system.instance_unrecoverable system.project_slo_violation system.project_drift system.project_cost_breach]
        .each do |signal|
        expect(engine.owner_for(engine::SIGNAL_BINDINGS.fetch(signal))).to eq("capacity-manager")
      end
      expect(declarations.owner_of("system.instance_pool_replenish")).to eq("capacity-manager")
      expect(declarations.owner_of("system.platform.scale_in")).to eq("capacity-manager")
      expect(declarations.owner_of("system.instance_cordon")).to eq("capacity-manager")
    end

    it "creates its own approval chain (4h, reject on timeout)" do
      chain = Ai::ApprovalChain.find_by(account: account, name: "Capacity Manager Actions")
      expect(chain).to be_present
      expect(chain.status).to eq("active")
      expect(chain.trigger_type).to eq("autonomy_action")
      expect(chain.timeout_hours).to eq(4)
      expect(chain.timeout_action).to eq("reject")
    end

    it "is idempotent across re-runs (no duplicate global row, no duplicate policy rows)" do
      reconcile!
      expect { load_seed!("system_capacity_manager_agent.rb"); reconcile! }
        .not_to change {
          [ Ai::Agent.global.where(name: "Capacity Manager").count,
            Ai::InterventionPolicy.where(account: account, ai_agent_id: principal.id).count ]
        }.from([ 1, declarations::CAPACITY_MANAGER_POLICIES.size ])
    end

    it "refuses to adopt a stray account-scoped agent of the same name (canonical rule)" do
      Ai::AgentTrustScore.where(agent_id: agent.id).delete_all
      Ai::InterventionPolicy.where(ai_agent_id: agent.id).delete_all
      agent.destroy!
      create(:ai_agent, account: account, name: "Capacity Manager", agent_type: "monitor")

      expect { load_seed!("system_capacity_manager_agent.rb") }
        .to raise_error(System::Seeds::AgentSetupHelpers::CanonicalAgentConflict, /Capacity Manager/)
    end
  end

  describe "the hierarchy seat (system_agent_hierarchy.rb)" do
    before do
      load_seed!("system_concierge_agent.rb")
      load_seed!("system_capacity_manager_agent.rb")
      load_seed!("system_agent_hierarchy.rb")
    end

    let(:root) { Ai::Agent.global.find_by!(source_key: "system-concierge") }

    it "attaches the agent under System Concierge with one active seed edge and a conservative depth-2 leaf policy" do
      edges = Ai::AgentLineage.for_child(agent.id).active
      expect(edges.pluck(:parent_agent_id)).to eq([ root.id ])
      expect(edges.first.spawn_reason).to eq("seed")
      expect(agent.reload.parent_agent_id).to eq(root.id)

      policy = Ai::DelegationPolicy.resolve_for(agent_id: agent.id, account_id: account.id)
      expect(policy).to be_present
      expect(policy.inheritance_policy).to eq("conservative")
      expect(policy.max_depth).to eq(2)
      expect(policy.allowed_delegate_types).to eq([])
      expect(policy.delegatable_actions).to eq([])

      report = System::Governance::HierarchyReconciler.new(account: account).drift
      expect(report.skipped).not_to include("capacity-manager(agent absent)")
      expect(report.missing_edges).to be_empty
      expect(report.missing_policies).to be_empty
    end
  end

  describe "skill bindings (system_skill_bindings_seed.rb)" do
    # Populate the registry the way the bindings seed does (autoload would
    # only register executors something has referenced).
    before(:all) do
      Dir.glob(Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb"))
         .each { |f| require_dependency f }
    end

    # attach_storage joined in HIER-P2SWEEP: it runs during subdomain
    # provisioning, so it belongs to the capacity plane, not the volume plane.
    CAPACITY_SKILLS = %w[
      system-replace-instance system-reap-instance system-relocate-workload
      system-scale-project system-provision-full-stack system-platform-resilience
      system-attach-storage
    ].freeze

    before do
      %w[fleet_autonomy_agent.rb system_concierge_agent.rb system_capacity_manager_agent.rb
         system_skills_seed.rb system_provisioning_skills_seed.rb system_dr_skills_seed.rb
         system_skill_bindings_seed.rb].each { |f| load_seed!(f) }
    end

    def bound_slugs(name)
      owner = Ai::Agent.global.find_by!(name: name)
      Ai::AgentSkill.where(ai_agent_id: owner.id, is_active: true).joins(:skill).pluck("ai_skills.slug")
    end

    it "materialises the seven capacity executors on the Capacity Manager" do
      expect(bound_slugs("Capacity Manager")).to match_array(CAPACITY_SKILLS)
    end

    it "no longer binds the moved executors to Fleet Autonomy, and keeps promote_replica there" do
      fleet = bound_slugs("Fleet Autonomy")
      expect(fleet & CAPACITY_SKILLS).to eq([])
      expect(fleet).to include("system-promote-replica")
    end

    it "keeps platform_resilience on the System Concierge too (the operator chat door)" do
      expect(bound_slugs("Infrastructure Generalist")).to include("system-platform-resilience")
    end
  end
end
