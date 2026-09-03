# frozen_string_literal: true

require "rails_helper"

# HIER-P1 — the system agent hierarchy as seeded data: System Concierge is the
# root, every domain agent hangs under it (and so does the CORE concierge, so
# an install carrying this extension has ONE forest) with exactly one active
# lineage edge and one delegation policy, written through
# Ai::Agents::HierarchyWriter. The reconciler's drift report is what the
# governance rake prints.
module SystemAgentHierarchySeeds
  AGENT_SEEDS = %w[
    fleet_autonomy_agent.rb
    system_concierge_agent.rb
    system_runtime_manager_agent.rb
    system_cve_responder_agent.rb
    system_disk_image_manager_agent.rb
    system_sdwan_manager_agent.rb
    system_topology_designer_agent.rb
    system_gitops_reconciler_agent.rb
  ].freeze

  DOMAIN_AGENTS = [
    "Fleet Autonomy", "SDWAN Manager", "CVE Responder", "Disk Image Manager",
    "Runtime Manager", "GitOps Reconciler", "System Topology Designer"
  ].freeze

  # HIER-P2DECL declared the four wave-1 managers on the attach list ahead of
  # their seeds (wave 2). Until those land, every seed run reports them as
  # skipped — DRIFT by the P1 ruling, never an error — and attaches nothing
  # for them. When wave 2 seeds them, move each into AGENT_SEEDS/DOMAIN_AGENTS
  # and delete it here.
  WAVE_2_KEYS = %w[capacity-manager storage-manager ingress-manager supply-chain-manager].freeze

  CORE_ROOT_SLUG = "powernode-assistant"
end

RSpec.describe "system_agent_hierarchy seed" do
  domain_agents = SystemAgentHierarchySeeds::DOMAIN_AGENTS

  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  # The CORE concierge comes from the core seeds; the extension hierarchy seed
  # attaches it under System Concierge (operator ruling: one forest).
  def load_core_concierge!
    silence_warnings { load Rails.root.join("db", "seeds", "ai_concierge_seed.rb") }
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }
  # ai_concierge_seed binds the concierge skill and raises without it.
  let!(:concierge_skill) { create(:ai_skill, account: account, slug: "powernode-concierge", name: "Powernode Concierge") }

  let(:root) { Ai::Agent.global.find_by(name: "System Concierge") }
  let(:core_root) { Ai::Agent.global.find_by(slug: SystemAgentHierarchySeeds::CORE_ROOT_SLUG) }

  def agent(name) = Ai::Agent.global.find_by!(name: name)
  def policy_for(agent) = Ai::DelegationPolicy.resolve_for(agent_id: agent.id, account_id: account.id)
  def reconciler = System::Governance::HierarchyReconciler.new(account: account)

  def seed_all!
    SystemAgentHierarchySeeds::AGENT_SEEDS.each { |f| load_seed!(f) }
    load_core_concierge!
    load_seed!("system_agent_hierarchy.rb")
  end

  describe "lineage" do
    before { seed_all! }

    it "attaches every domain agent under System Concierge with exactly one active edge" do
      expect(root).to be_present
      expect(Ai::AgentLineage.for_child(root.id)).to be_empty
      expect(root.parent_agent_id).to be_nil

      domain_agents.each do |name|
        child = agent(name)
        edges = Ai::AgentLineage.for_child(child.id).active
        expect(edges.pluck(:parent_agent_id)).to eq([ root.id ]), "#{name} should have one active edge to the root"
        expect(edges.first.spawn_reason).to eq("seed")
        expect(edges.first.account_id).to eq(account.id)
        expect(child.parent_agent_id).to eq(root.id)
      end
    end

    it "attaches the CORE concierge too, so System Concierge is the only root" do
      expect(core_root).to be_present
      edges = Ai::AgentLineage.for_child(core_root.id).active
      expect(edges.pluck(:parent_agent_id)).to eq([ root.id ])
      expect(core_root.reload.parent_agent_id).to eq(root.id)
      expect(Ai::AgentLineage.for_parent(root.id).active.count).to eq(domain_agents.size + 1)

      rootless = Ai::Agent.global.where(parent_agent_id: nil).pluck(:name)
      expect(rootless).to eq([ "System Concierge" ])
    end

    it "reports the four wave-1 managers as skipped (drift), not as an error, until wave 2 seeds them" do
      result = System::Governance::HierarchyReconciler.new(account: account).reconcile!
      expect(result.skipped).to match_array(SystemAgentHierarchySeeds::WAVE_2_KEYS.map { |k| "#{k}(agent absent)" })
      expect(result.attached).to eq(domain_agents.size + 1)
    end

    it "is idempotent: a re-run adds no edge and no policy" do
      edges    = Ai::AgentLineage.count
      policies = Ai::DelegationPolicy.count

      load_seed!("system_agent_hierarchy.rb")

      expect(Ai::AgentLineage.count).to eq(edges)
      expect(Ai::DelegationPolicy.count).to eq(policies)
    end
  end

  describe "delegation policies" do
    before { seed_all! }

    # Keyed on the seeding account rather than as an account_id-NULL canonical
    # row, so the seed is legal under both the pre- and post-HIER-P0 schema.
    it "writes exactly one policy per system agent, keyed on the seeding account" do
      ([ "System Concierge" ] + domain_agents).each do |name|
        rows = Ai::DelegationPolicy.where(agent_id: agent(name).id)
        expect(rows.count).to eq(1), "#{name} should carry exactly one delegation policy"
        expect(rows.first.account_id).to eq(account.id)
        expect(policy_for(agent(name))).to eq(rows.first)
      end
    end

    it "gives a domain agent conservative/depth-2 and leaves its delegate types open (it is a leaf)" do
      fleet = policy_for(agent("Fleet Autonomy"))
      expect(fleet.inheritance_policy).to eq("conservative")
      expect(fleet.max_depth).to eq(2)
      expect(fleet.allowed_delegate_types).to eq([])
      expect(fleet.delegatable_actions).to eq([])
    end

    # The column's vocabulary is Ai::Agent#agent_type (allows_delegate_type?),
    # NOT skill slugs or PolicyDeclarations categories: writing those would
    # refuse every delegation instead of scoping it.
    it "expresses the Concierge's 'any system agent' as the agent_typeS the system agents carry" do
      concierge = policy_for(root)
      expect(concierge.inheritance_policy).to eq("moderate")
      expect(concierge.max_depth).to eq(3)

      declared_types = ([ "System Concierge" ] + domain_agents).map { |n| agent(n).agent_type }.uniq.sort
      expect(concierge.allowed_delegate_types).to eq(declared_types)
      expect(concierge.allowed_delegate_types).to include("monitor", "assistant")
      expect(concierge.delegatable_actions).to eq([])
    end

    # The consumer, not the column: a seeded policy must still ALLOW the
    # delegations the hierarchy exists to describe.
    it "still allows a real delegation through DelegationAuthorityService" do
      authority = Ai::Autonomy::DelegationAuthorityService.new(account: account)

      domain_agents.each do |name|
        result = authority.validate_delegation(
          delegator: root, delegate: agent(name), task: { action_type: "execute" }
        )
        expect(result[:allowed]).to be(true), "Concierge → #{name} refused: #{result[:reason]}"
      end

      leaf = authority.validate_delegation(
        delegator: agent("Fleet Autonomy"), delegate: agent("CVE Responder"),
        task: { action_type: "execute" }
      )
      expect(leaf[:allowed]).to be(true), "Fleet Autonomy → CVE Responder refused: #{leaf[:reason]}"
    end
  end

  describe "drift report" do
    # Not CLEAN after the seed any more: the four wave-1 managers are declared
    # and unseeded, so the report is drifted by exactly their skipped lines
    # and nothing else — no missing edge, no missing policy.
    it "is clean but for the unseeded wave-1 managers after the seed" do
      seed_all!

      report = reconciler.drift
      expect(report).to be_drifted
      expect(report.skipped).to match_array(SystemAgentHierarchySeeds::WAVE_2_KEYS.map { |k| "#{k}(agent absent)" })
      expect(report.missing_edges).to be_empty
      expect(report.missing_policies).to be_empty
      expect(report.present.size).to eq(domain_agents.size + 1)
    end

    it "attaches a wave-1 manager on the first run after its agent exists, with the P1 leaf delegation" do
      seed_all!
      identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("capacity-manager")
      capacity = Ai::Agent.create!(
        name: identity[:name], agent_type: identity[:agent_type], source_key: "capacity-manager",
        status: "active", account: nil, creator: user, provider: provider,
        system_prompt: "stub for the wave-2 seed"
      )

      load_seed!("system_agent_hierarchy.rb")

      expect(Ai::AgentLineage.for_child(capacity.id).active.pluck(:parent_agent_id)).to eq([ root.id ])
      policy = policy_for(capacity)
      expect(policy.inheritance_policy).to eq("conservative")
      expect(policy.max_depth).to eq(2)
      expect(policy.allowed_delegate_types).to eq([])
      expect(reconciler.drift.skipped).to match_array(
        (SystemAgentHierarchySeeds::WAVE_2_KEYS - %w[capacity-manager]).map { |k| "#{k}(agent absent)" }
      )
    end

    it "names a terminated edge and a deleted policy" do
      seed_all!
      cve = agent("CVE Responder")
      Ai::AgentLineage.for_child(cve.id).active.first.terminate!(reason: "spec")
      Ai::DelegationPolicy.where(agent_id: agent("SDWAN Manager").id).delete_all

      report = reconciler.drift
      expect(report).to be_drifted
      expect(report.missing_edges).to eq([ "system-concierge/cve-responder" ])
      expect(report.missing_policies).to eq([ "sdwan-manager" ])

      # and reconcile! repairs exactly that (the wave-1 skips remain)
      reconciler.reconcile!
      after = reconciler.drift
      expect(after.missing_edges).to be_empty
      expect(after.missing_policies).to be_empty
      expect(after.skipped).to match_array(SystemAgentHierarchySeeds::WAVE_2_KEYS.map { |k| "#{k}(agent absent)" })
    end

    it "treats an unseeded agent as drift, not as clean" do
      (SystemAgentHierarchySeeds::AGENT_SEEDS - [ "system_cve_responder_agent.rb" ]).each { |f| load_seed!(f) }
      load_core_concierge!
      load_seed!("system_agent_hierarchy.rb")

      report = reconciler.drift
      expect(report).to be_drifted
      expect(report.skipped).to include("cve-responder(agent absent)")
      expect(report.skipped - SystemAgentHierarchySeeds::WAVE_2_KEYS.map { |k| "#{k}(agent absent)" })
        .to eq([ "cve-responder(agent absent)" ])
      expect(report.missing_edges).to be_empty
    end

    it "treats an absent CORE concierge as drift, never as an invented edge" do
      SystemAgentHierarchySeeds::AGENT_SEEDS.each { |f| load_seed!(f) }
      load_seed!("system_agent_hierarchy.rb")

      report = reconciler.drift
      expect(report).to be_drifted
      expect(report.skipped - SystemAgentHierarchySeeds::WAVE_2_KEYS.map { |k| "#{k}(agent absent)" })
        .to eq([ "core-concierge(agent absent)" ])
      expect(report.missing_edges).to be_empty
    end

    it "reports everything skipped when the root is absent" do
      report = reconciler.drift
      expect(report).to be_drifted
      expect(report.skipped).to include("system-concierge(agent absent)")
    end
  end
end
