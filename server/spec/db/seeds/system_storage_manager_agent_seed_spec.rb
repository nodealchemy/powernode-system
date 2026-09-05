# frozen_string_literal: true

require "rails_helper"

# HIER-P2C — the Storage Manager agent seed and its wiring. HIER-P2DECL declared
# the identity, the policy set (STORAGE_MANAGER_POLICIES), the sensor owner and
# the hierarchy seat ahead of this seed; these examples hold the wave-2 contract:
#   1. the seed creates the GLOBAL canonical (never adopts an account row),
#   2. its routing description / prompt / tool families are the ones HIER-P1B
#      exports verbatim as the Claude Code counterpart,
#   3. the declared set is written at the agent shape and nothing else is,
#   4. the P1 hierarchy seam attaches it under System Concierge on the first
#      run after it exists (it is no longer a skipped wave-2 key), and
#   5. the restore executor is bound HERE, not on Fleet Autonomy any more.
RSpec::Matchers.define_negated_matcher :not_change, :change

RSpec.describe "system_storage_manager_agent seed" do
  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  # Populate the SkillBindings registry the way system_skill_bindings_seed.rb
  # does (in production the executors autoload on reference).
  before(:all) do
    glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
    Dir.glob(glob).each { |f| require_dependency f }
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  let(:identity) { System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("storage-manager") }
  let(:declared) { System::Governance::PolicyDeclarations::STORAGE_MANAGER_POLICIES }
  let(:agent)    { Ai::Agent.global.find_by(name: identity[:name]) }

  describe "the seeded agent" do
    before { load_seed!("system_storage_manager_agent.rb") }

    it "creates the GLOBAL canonical monitor the declarations name, keyed storage-manager" do
      expect(agent).to be_present
      expect(agent.account_id).to be_nil
      expect(agent.is_system).to be true
      expect(agent.source_key).to eq("storage-manager")
      expect(agent.slug).to eq("storage-manager")
      expect(agent.agent_type).to eq(identity[:agent_type])
      expect(agent.status).to eq("active")
      expect(agent.autonomy_config).to include("extension" => "system", "scope" => "storage")
    end

    # HIER-P1B exports the description verbatim as the Claude Code subagent
    # description, which the CC Agent tool ROUTES on: it must say when to use
    # this agent and name the sibling for the adjacent domain, inside the
    # exporter's budget.
    it "carries a routing description within the exporter's budget that names its hand-offs" do
      expect(agent.description.length).to be <= Ai::ClaudeExport::RoutingDescription::MAX_CHARS
      # The exporter lifts only the FIRST sentence into the trigger clause and
      # truncates it with an ellipsis past MAX_DESCRIPTION_CHARS.
      first_sentence = agent.description.split(/(?<=[.!?])\s+/).first
      expect(first_sentence.length).to be <= Ai::ClaudeExport::RoutingDescription::MAX_DESCRIPTION_CHARS
      expect(Ai::ClaudeExport::RoutingDescription.compact_description(agent.description)).not_to end_with("…")
      expect(agent.description).to match(/Use (this agent )?when/i)
      expect(agent.description).to match(/Do not use for/i)
      expect(agent.description).to include("Capacity Manager")
      expect(agent.description).to include("Fleet Autonomy")
    end

    it "carries a data-protection-first system prompt naming the verbs, the restore semantics and the hand-offs" do
      prompt = agent.system_prompt.to_s
      expect(prompt.strip).not_to be_empty
      expect(prompt).to include("Storage Manager")
      declared.each_key { |category| expect(prompt).to include(category) }
      expect(prompt).to include("restored_in_place")
      expect(prompt).to include("swap_into_place")
      expect(prompt).to include("take_snapshot_first")
      expect(prompt).to include("system_delete_volume_snapshot")
      expect(prompt).to include("system_cleanup_storage_migration")
      expect(prompt).to include("system_revert_storage_migration_binding")
      expect(prompt).to include("system_test_nfs_export")
      expect(prompt).to include("Capacity Manager")
      expect(prompt).to include("Fleet Autonomy")
    end

    it "requests a reasoning-tier model via model_requirements and pins no model id" do
      expect(agent.mcp_metadata.dig("model_config", "model_requirements")).to eq("tier" => "reasoning")
      expect(agent.mcp_metadata.dig("model_config", "model")).to be_blank
    end

    # The first canonical with a tool scope (HIER-P1B: "no canonical has
    # tool_access"). ToolAllowlist / AgentToolBridgeService match a family by
    # exact registry name or `<family>_` prefix, and a list matching NOTHING
    # fails open to the whole registry — so every family must match, and the
    # scoped set must be the storage surface and not the fleet's.
    it "scopes tool access to the storage families and every family matches a registered tool" do
      families = agent.mcp_metadata.dig("tool_access", "tool_families")
      expect(families).to be_an(Array)
      expect(families).not_to be_empty
      expect(agent.mcp_metadata.dig("tool_access", "enabled")).to be_nil
      expect(agent.mcp_metadata.dig("tool_access", "full_registry")).to be_nil

      registered = Ai::Tools::PlatformApiToolRegistry.all_tools.keys.map(&:to_s)
      unmatched = families.reject do |family|
        registered.any? { |name| name == family || name.start_with?("#{family}_") }
      end
      expect(unmatched).to be_empty, "tool_families matching no registered tool: #{unmatched.inspect}"

      scoped = Ai::ClaudeExport::ToolAllowlist.platform_actions_for(agent)
      expect(scoped).to be_an(Array)
      expect(scoped).to include(
        "system_list_volumes", "system_get_volume", "system_attach_volume", "system_detach_volume",
        "system_snapshot_volume", "system_list_volume_snapshots", "system_restore_volume_snapshot",
        "system_delete_volume_snapshot", "system_list_storage_assignments_by_owner",
        "system_assign_storage_owner", "system_storage_chown_status", "system_storage_chown_retry",
        "system_migrate_storage_component", "system_approve_storage_migration",
        "system_cancel_storage_migration", "system_cleanup_storage_migration",
        "system_revert_storage_migration_binding", "system_get_storage_recommendations",
        "system_test_nfs_export", "system_list_instances", "system_get_instance"
      )
      # The prefix rule admits two names beyond the exact list:
      # `system_delete_volume_snapshot` (already listed by exact name, so it
      # does not widen anything) and the read verb `system_get_instance_pool`.
      # This equality oracle is what pins that set — a third admission
      # registered later fails here instead of widening the grant quietly.
      expect(scoped - families).to eq([ "system_get_instance_pool" ])
      expect(scoped).not_to include("system_provision_instance", "system_terminate_instance",
                                    "system_sdwan_list_networks", "system_deploy_platform",
                                    "system_report_storage_migration_progress")
    end

    it "bootstraps a monitored trust score" do
      score = Ai::AgentTrustScore.find_by(agent_id: agent.id)
      expect(score).to be_present
      expect(score.account_id).to eq(account.id)
      expect(score.tier).to eq("monitored")
      expect(score.overall_score.to_f.round(2)).to eq(0.72)
    end

    it "writes NO policy row itself — PolicyReconciler is the single writer (ruling 7)" do
      expect(Ai::InterventionPolicy.where(account: account)).to be_empty
    end

    it "carries exactly the declared STORAGE_MANAGER_POLICIES at the agent shape once reconciled" do
      System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!
      principal = System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: "storage-manager")
      rows = Ai::InterventionPolicy
        .where(account: account, ai_agent_id: principal.id, scope: "agent", is_active: true)
        .pluck(:action_category, :policy).to_h
      expect(rows).to eq(declared)
      expect(rows).to eq(
        "system.storage_assignment_reconcile" => "notify_and_proceed",
        # IMP-c22215ae9546 — the scheduled-snapshot create lane
        # (snapshot_policy_sensor). notify_and_proceed: the project's declared
        # interval is the opt-in, so the lane proceeds and the operator is
        # notified rather than re-asked on every interval.
        "system.volume_snapshot_create"       => "notify_and_proceed",
        "system.restore_volume"               => "require_approval",
        "system.volume_snapshot_delete"       => "require_approval"
      )
    end

    it "creates its own approval chain, rejecting on timeout" do
      chain = Ai::ApprovalChain.find_by(account: account, name: "Storage Manager Actions")
      expect(chain).to be_present
      expect(chain.trigger_type).to eq("autonomy_action")
      expect(chain.status).to eq("active")
      expect(chain.timeout_action).to eq("reject")
      expect(chain.timeout_hours).to be > 0
    end

    it "is idempotent across re-runs (no duplicate global row, policy or chain)" do
      expect { load_seed!("system_storage_manager_agent.rb") }
        .to not_change { Ai::Agent.global.where(name: identity[:name]).count }.from(1)
        .and not_change { Ai::InterventionPolicy.where(ai_agent_id: agent.id).count }
        .and not_change { Ai::ApprovalChain.where(name: "Storage Manager Actions").count }.from(1)
    end
  end

  describe "the canonical rule" do
    it "refuses to adopt a stray ACCOUNT-scoped agent of the same name" do
      create(:ai_agent, account: account, name: identity[:name], agent_type: identity[:agent_type])

      expect { load_seed!("system_storage_manager_agent.rb") }
        .to raise_error(System::Seeds::AgentSetupHelpers::CanonicalAgentConflict, /storage-manager/)
      expect(Ai::Agent.global.where(name: identity[:name])).to be_empty
    end
  end

  describe "the hierarchy seam (HIER-P1)" do
    let!(:concierge_skill) { create(:ai_skill, account: account, slug: "powernode-concierge", name: "Powernode Concierge") }
    let(:root) { Ai::Agent.global.find_by(source_key: "system-concierge") }

    before do
      load_seed!("system_concierge_agent.rb")
      load_seed!("system_storage_manager_agent.rb")
      silence_warnings { load Rails.root.join("db", "seeds", "ai_concierge_seed.rb") }
      load_seed!("system_agent_hierarchy.rb")
    end

    it "attaches the Storage Manager under System Concierge with a conservative depth-2 leaf delegation" do
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

    it "is no longer reported as a skipped wave-2 key" do
      report = System::Governance::HierarchyReconciler.new(account: account).drift
      expect(report.skipped).not_to include("storage-manager(agent absent)")
      expect(report.missing_edges).to be_empty
      expect(report.missing_policies).to be_empty
    end
  end

  describe "sensor owner gating (HIER-P2A)" do
    before do
      load_seed!("fleet_autonomy_agent.rb")
      load_seed!("system_storage_manager_agent.rb")
    end

    it "gates the storage_assignment_drift binding AS the Storage Manager, with no owner-missing event" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch("system.storage_assignment_drift")
      expect(System::Fleet::DecisionEngine.owner_for(binding)).to eq("storage-manager")
      expect(binding[:action_category]).to eq("system.storage_assignment_reconcile")

      fleet = Ai::Agent.global.find_by!(name: "Fleet Autonomy")
      service = System::Fleet::FleetAutonomyService.new(account: account, agent: fleet)
      expect(System::Fleet::EventBroadcaster).not_to receive(:emit!)
        .with(hash_including(kind: System::Fleet::FleetAutonomyService::OWNER_MISSING_EVENT_KIND))

      gate = service.for_owner("storage-manager")
      expect(gate).not_to equal(service)
      # HIER-P2I: the gate acts as the account's CLONE of the canonical, never
      # the canonical itself.
      expect(gate.agent.id).to eq(
        System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: "storage-manager").id
      )
      expect(gate.agent.cloned_from_id).to eq(agent.id)
      expect(gate.owner_key).to eq("storage-manager")
    end
  end

  describe "skill bindings" do
    before do
      load_seed!("fleet_autonomy_agent.rb")
      load_seed!("system_concierge_agent.rb")
      load_seed!("system_storage_manager_agent.rb")
      %w[system_skills_seed.rb system_provisioning_skills_seed.rb system_dr_skills_seed.rb
         system_skill_bindings_seed.rb].each { |f| load_seed!(f) }
    end

    it "registers RestoreVolumeExecutor on the Storage Manager only" do
      registration = System::Ai::Skills::SkillBindings.all.find do |r|
        r[:executor].name == "System::Ai::Skills::RestoreVolumeExecutor"
      end
      expect(registration).to be_present
      # The registry stores SOURCE KEYS now, not display names.
      expect(registration[:agents]).to eq([ "storage-manager" ])
    end

    it "materialises system-restore-volume on the Storage Manager and not on Fleet Autonomy" do
      skill = Ai::Skill.find_by!(slug: "system-restore-volume")
      fleet = Ai::Agent.global.find_by!(name: "Fleet Autonomy")

      expect(Ai::AgentSkill.where(ai_agent_id: agent.id, ai_skill_id: skill.id)).to exist
      expect(Ai::AgentSkill.where(ai_agent_id: fleet.id, ai_skill_id: skill.id)).not_to exist
      expect(agent.skill_slugs).to include("system-restore-volume")
    end
  end
end
