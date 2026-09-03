# frozen_string_literal: true

require "rails_helper"

# HIER-P2F — the Disk Image Manager made whole: a GLOBAL seeded canonical with
# a ROUTING description (what HIER-P1B exports as the Claude Code subagent
# description), a `tool_access.tool_families` scope naming only the disk-image
# MCP verbs (what the exporter turns into the `tools:` allowlist and what the
# tool bridge serves the agent), its declared policy set, a chain, a trust
# bootstrap, a seat under System Concierge, and — for the first time — skills:
# the three disk-image executors bind to it.
RSpec.describe "system_disk_image_manager_agent seed" do
  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  let(:agent) { Ai::Agent.global.find_by(name: "Disk Image Manager") }

  # HIER-P2F review — the RUNTIME door (AgentToolBridgeService#scope_to_tool_families)
  # has no bootstrap union of its own, unlike the exporter's ToolAllowlist: a
  # family list is the whole catalog this agent is served at run time. So the
  # investigate lane's reads (its declared
  # `system.disk_image_publication_investigate` row) and the two skill-discovery
  # verbs are listed explicitly, the way the Topology Designer's seed lists them.
  DISK_IMAGE_TOOL_FAMILIES = %w[
    system_list_disk_image_publications
    system_set_default_disk_image_publication
    system_revert_disk_image
    system_set_disk_image_retention
    system_list_disk_image_webhooks
    system_recent_signals
    system_list_tasks
    system_get_task
    discover_skills
    get_skill_context
  ].freeze

  describe "the seeded agent" do
    before { load_seed!("system_disk_image_manager_agent.rb") }

    it "is a GLOBAL canonical monitor keyed on its source_key" do
      expect(agent).to be_present
      expect(agent.account_id).to be_nil
      expect(agent.is_system).to be true
      expect(agent.source_key).to eq("disk-image-manager")
      expect(agent.agent_type).to eq("monitor")
      expect(agent.status).to eq("active")
    end

    it "carries a routing description: a trigger, an exclusion naming the sibling, within the export budget" do
      description = agent.description.to_s
      expect(description.length).to be <= Ai::ClaudeExport::RoutingDescription::MAX_CHARS
      expect(description).to match(/Use when/)
      expect(description).to match(/Do not use for/)
      expect(description).to include("Fleet Autonomy")
      expect(description).to match(/promot/i)
    end

    it "scopes tool access to the disk-image MCP verbs, every one a registered action" do
      families = agent.mcp_metadata.dig("tool_access", "tool_families")
      expect(families).to eq(DISK_IMAGE_TOOL_FAMILIES)

      registered = Ai::Tools::PlatformApiToolRegistry.all_tools.keys.map(&:to_s)
      expect(families - registered).to be_empty
    end

    it "derives a Claude Code tools allowlist of exactly the bootstrap verbs plus those families" do
      registry = Ai::ClaudeExport::ToolAllowlist::Registry.snapshot
      tools = Ai::ClaudeExport::ToolAllowlist.for(agent, registry: registry)
      platform_tools = tools.select { |t| t.start_with?(Ai::ClaudeExport::ToolAllowlist::MCP_PREFIX) }
                            .map { |t| t.delete_prefix(Ai::ClaudeExport::ToolAllowlist::MCP_PREFIX) }
      expect(platform_tools).to match_array(Ai::ClaudeExport::ToolAllowlist::BOOTSTRAP_ACTIONS | DISK_IMAGE_TOOL_FAMILIES)
    end

    it "requests its model by tier (standard — a 5-minute monitor), never a pinned model id" do
      requirements = agent.mcp_metadata.dig("model_config", "model_requirements")
      expect(requirements).to eq("tier" => "standard")
      expect(agent.mcp_metadata.dig("model_config", "model")).to be_blank
    end

    it "keeps its trust bootstrap (monitored, 0.70)" do
      score = Ai::AgentTrustScore.find_by(agent_id: agent.id)
      expect(score.tier).to eq("monitored")
      expect(score.overall_score.to_f.round(2)).to eq(0.70)
    end

    it "owns exactly the declared DISK_IMAGE_MANAGER_POLICIES rows" do
      rows = Ai::InterventionPolicy
        .where(account: account, ai_agent_id: agent.id, scope: "agent", is_active: true)
        .pluck(:action_category, :policy).to_h
      expect(rows).to eq(System::Governance::PolicyDeclarations::DISK_IMAGE_MANAGER_POLICIES)
    end

    it "keeps its approval chain" do
      chain = Ai::ApprovalChain.find_by(account: account, name: "Disk Image Manager Actions")
      expect(chain.status).to eq("active")
      expect(chain.timeout_hours).to eq(12)
      expect(chain.timeout_action).to eq("reject")
    end

    it "is idempotent (no duplicate global row, no second policy set)" do
      expect { load_seed!("system_disk_image_manager_agent.rb") }
        .not_to change { [ Ai::Agent.global.where(name: "Disk Image Manager").count,
                           Ai::InterventionPolicy.where(ai_agent_id: agent.id).count ] }
    end
  end

  describe "its seat in the hierarchy" do
    before do
      load_seed!("system_concierge_agent.rb")
      load_seed!("system_disk_image_manager_agent.rb")
      load_seed!("system_agent_hierarchy.rb")
    end

    it "hangs under System Concierge with one seed edge and a conservative depth-2 delegation policy" do
      root = Ai::Agent.global.find_by!(name: "System Concierge")
      edges = Ai::AgentLineage.for_child(agent.id).active
      expect(edges.pluck(:parent_agent_id)).to eq([ root.id ])
      expect(edges.first.spawn_reason).to eq("seed")
      expect(agent.reload.parent_agent_id).to eq(root.id)

      policy = Ai::DelegationPolicy.resolve_for(agent_id: agent.id, account_id: account.id)
      expect(policy.inheritance_policy).to eq("conservative")
      expect(policy.max_depth).to eq(2)
      expect(policy.allowed_delegate_types).to eq([])
    end
  end

  describe "its skills" do
    before do
      load_seed!("system_disk_image_manager_agent.rb")
      load_seed!("system_skills_seed.rb")
      load_seed!("system_provisioning_skills_seed.rb")
      load_seed!("system_dr_skills_seed.rb")
      load_seed!("system_skill_bindings_seed.rb")
    end

    it "binds the three disk-image executors, and nothing else" do
      expect(agent.reload.skill_slugs).to contain_exactly(
        "system-disk-image-promote", "system-disk-image-rollback", "system-disk-image-retention"
      )
    end

    it "seeds every bound skill as a GLOBAL row with its executor class in metadata" do
      %w[system-disk-image-promote system-disk-image-rollback system-disk-image-retention].each do |slug|
        skill = Ai::Skill.find_by!(slug: slug)
        expect(skill.metadata["executor_class"]).to start_with("System::Ai::Skills::DiskImage")
        expect(skill.is_system).to be true
      end
    end
  end
end
