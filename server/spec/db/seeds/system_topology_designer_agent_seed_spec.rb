# frozen_string_literal: true

require "rails_helper"

# HIER-P2F — the System Topology Designer takes the topology set: its seed now
# consumes PolicyDeclarations::TOPOLOGY_DESIGNER_POLICIES like its siblings
# (PolicyReconciler still writes the same rows on every later boot), carries a
# "Topology Designer Actions" approval chain, a routing description, a
# `tool_access.tool_families` scope over the topology surface, and the three
# composer executors bind to it through the `topology_designer` alias.
RSpec.describe "system_topology_designer_agent seed" do
  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  let(:agent) { Ai::Agent.global.find_by(name: "System Topology Designer") }

  TOPOLOGY_COMPOSER_SLUGS = %w[
    system-sdwan-federation-compose system-multi-tenant-isolation system-service-discovery-composer
  ].freeze

  describe "the seeded agent" do
    before { load_seed!("system_topology_designer_agent.rb") }

    it "is a GLOBAL canonical assistant keyed on its source_key" do
      expect(agent).to be_present
      expect(agent.account_id).to be_nil
      expect(agent.is_system).to be true
      expect(agent.source_key).to eq("topology-designer")
      expect(agent.agent_type).to eq("assistant")
    end

    it "carries a routing description within the export budget, naming the SDWAN Manager as the sibling" do
      description = agent.description.to_s
      expect(description.length).to be <= Ai::ClaudeExport::RoutingDescription::MAX_CHARS
      expect(description).to match(/Use when/)
      expect(description).to match(/Do not use for/)
      expect(description).to include("SDWAN Manager")
    end

    # HIER-P2F review — EXACT NAMES, never the bare `system_sdwan` prefix. The
    # matcher is `name == family || name.start_with?("#{family}_")`
    # (ToolAllowlist#in_families?, AgentToolBridgeService#tool_in_families?), so
    # one bare prefix would hand this design agent the whole SDWAN mutation
    # surface — deletes, VIP failover, user-device issuance — the very work its
    # own description sends to the SDWAN Manager. The equality oracle below is
    # what keeps that true: a verb registered LATER under a listed name's prefix
    # widens the grant, and this example fails when it does.
    it "scopes tool access by exact name — reads plus composition writes, no destructive SDWAN verb" do
      families = agent.mcp_metadata.dig("tool_access", "tool_families")
      expect(families).not_to include("system_sdwan")
      expect(families).to include("system_sdwan_compile_ovn_plan", "system_sdwan_federation_compose",
                                  "system_multi_tenant_isolation", "system_service_discovery_compose")
      expect(families).not_to include("docker_get_network") # named by concierge_tool_filter, registered nowhere

      registered = Ai::Tools::PlatformApiToolRegistry.all_tools.keys.map(&:to_s)
      unmatched = families.reject { |f| registered.any? { |n| n == f || n.start_with?("#{f}_") } }
      expect(unmatched).to be_empty, "tool_families matching no registered action: #{unmatched.inspect}"

      registry = Ai::ClaudeExport::ToolAllowlist::Registry.snapshot
      exported = Ai::ClaudeExport::ToolAllowlist.for(agent, registry: registry)
        .select { |t| t.start_with?(Ai::ClaudeExport::ToolAllowlist::MCP_PREFIX) }
        .map { |t| t.delete_prefix(Ai::ClaudeExport::ToolAllowlist::MCP_PREFIX) }
      expect(exported).to match_array(Ai::ClaudeExport::ToolAllowlist::BOOTSTRAP_ACTIONS | families)

      remediation = exported.grep(/\Asystem_sdwan_(delete|detach|attach|failover|issue|revoke|accept|set_data_residency|update_account|update_peer|set_peer)/)
      expect(remediation).to be_empty, "day-to-day SDWAN remediation verbs leaked into the grant: #{remediation.inspect}"
    end

    it "keeps the reasoning tier and the trust bootstrap" do
      expect(agent.mcp_metadata.dig("model_config", "model_requirements")).to eq("tier" => "reasoning")
      expect(agent.mcp_metadata.dig("model_config", "model")).to be_blank
      score = Ai::AgentTrustScore.find_by(agent_id: agent.id)
      expect(score.tier).to eq("monitored")
      expect(score.overall_score.to_f.round(2)).to eq(0.72)
    end

    it "writes exactly the declared TOPOLOGY_DESIGNER_POLICIES rows on the seeding account" do
      rows = Ai::InterventionPolicy
        .where(account: account, ai_agent_id: agent.id, scope: "agent", is_active: true)
        .pluck(:action_category, :policy).to_h
      expect(rows).to eq(System::Governance::PolicyDeclarations::TOPOLOGY_DESIGNER_POLICIES)
    end

    it "agrees with PolicyReconciler: a reconcile after the seed creates nothing" do
      expect { System::Governance::PolicyReconciler.new(account: account).reconcile! }
        .not_to change { Ai::InterventionPolicy.where(ai_agent_id: agent.id).count }
    end

    it "creates the Topology Designer Actions approval chain" do
      chain = Ai::ApprovalChain.find_by(account: account, name: "Topology Designer Actions")
      expect(chain).to be_present
      expect(chain.trigger_type).to eq("autonomy_action")
      expect(chain.status).to eq("active")
      expect(chain.timeout_action).to eq("reject")
      expect(chain.steps.first["approvers"]).to eq([ { "type" => "permission", "value" => "system.infra_tasks.control" } ])
    end

    it "is idempotent (no duplicate global row, chain or policy)" do
      expect { load_seed!("system_topology_designer_agent.rb") }
        .not_to change { [ Ai::Agent.global.where(name: "System Topology Designer").count,
                           Ai::ApprovalChain.where(account: account, name: "Topology Designer Actions").count,
                           Ai::InterventionPolicy.where(ai_agent_id: agent.id).count ] }
    end
  end

  describe "its seat in the hierarchy" do
    before do
      load_seed!("system_concierge_agent.rb")
      load_seed!("system_topology_designer_agent.rb")
      load_seed!("system_agent_hierarchy.rb")
    end

    it "hangs under System Concierge with one seed edge and a conservative depth-2 delegation policy" do
      root = Ai::Agent.global.find_by!(name: "System Concierge")
      edges = Ai::AgentLineage.for_child(agent.id).active
      expect(edges.pluck(:parent_agent_id)).to eq([ root.id ])
      expect(agent.reload.parent_agent_id).to eq(root.id)

      policy = Ai::DelegationPolicy.resolve_for(agent_id: agent.id, account_id: account.id)
      expect(policy.inheritance_policy).to eq("conservative")
      expect(policy.max_depth).to eq(2)
    end
  end

  describe "its skills" do
    before do
      load_seed!("system_topology_designer_agent.rb")
      load_seed!("system_skills_seed.rb")
      load_seed!("system_provisioning_skills_seed.rb")
      load_seed!("system_dr_skills_seed.rb")
      load_seed!("system_skill_bindings_seed.rb")
    end

    it "binds the SDWAN compose family AND the three topology composers" do
      expect(agent.reload.skill_slugs).to contain_exactly(
        "system-sdwan-host-bridge-compose", "system-sdwan-ovn-compose-topology",
        "system-sdwan-ipfix-collector-compose", "system-sdwan-compose-full-topology",
        "system-sdwan-ovn-apply-acl", *TOPOLOGY_COMPOSER_SLUGS
      )
    end

    it "binds the composers through the topology_designer alias (not a spelled-out name)" do
      %w[sdwan_federation_compose multi_tenant_isolation service_discovery_composer].each do |base|
        source = File.read(Rails.root.join("..", "extensions", "system", "server", "app", "services",
                                           "system", "ai", "skills", "#{base}_executor.rb"))
        expect(source).to match(/^\s*binds_to "topology_designer"/), "#{base}_executor.rb should bind via the alias"
      end
      expect(System::Ai::Skills::SkillBindings::AGENT_ALIASES.fetch("topology_designer")).to eq("System Topology Designer")
    end
  end
end
