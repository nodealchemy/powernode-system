# frozen_string_literal: true

require "rails_helper"

# HIER-P4 — the "System Operations" team as seeded data: a global canonical
# Ai::TeamTemplate managed by System Concierge, whose members are the eleven
# domain agents the HIER-P1 hierarchy hangs under it, materialised on the
# admin account as a hierarchical / manager_led / hub_spoke Ai::AgentTeam on
# the account's executing principals (ruling 8). Team, lineage forest and
# delegation graph are three views of ONE structure: a freshly seeded install
# reports no team drift, a removed lineage edge shows as team drift, and a
# delegate type the Concierge's policy admits that no member carries shows as
# drift. The reconciler repairs MEMBERSHIP on `system:governance:reconcile`;
# edges and policies keep their own writers.
module SystemOperationsTeamSeeds
  AGENT_SEEDS = %w[
    fleet_autonomy_agent.rb
    system_concierge_agent.rb
    system_runtime_manager_agent.rb
    system_cve_responder_agent.rb
    system_disk_image_manager_agent.rb
    system_sdwan_manager_agent.rb
    system_topology_designer_agent.rb
    system_gitops_reconciler_agent.rb
    system_capacity_manager_agent.rb
    system_storage_manager_agent.rb
    system_ingress_manager_agent.rb
    system_supply_chain_manager_agent.rb
  ].freeze

  TEMPLATE_SLUG = "system-operations"

  # canonical slug => [member role, lead?]
  ROSTER = {
    "system-concierge"         => [ "manager",    true ],
    "fleet-autonomy"           => [ "executor",   false ],
    "sdwan-manager"            => [ "specialist", false ],
    "cve-responder"            => [ "executor",   false ],
    "disk-image-manager"       => [ "specialist", false ],
    "runtime-manager"          => [ "executor",   false ],
    "gitops-reconciler"        => [ "executor",   false ],
    "system-topology-designer" => [ "specialist", false ],
    "capacity-manager"         => [ "specialist", false ],
    "storage-manager"          => [ "specialist", false ],
    "ingress-manager"          => [ "specialist", false ],
    "supply-chain-manager"     => [ "specialist", false ]
  }.freeze
end

RSpec.describe "system_operations_team seed" do
  RSpec::Matchers.define_negated_matcher :not_change, :change

  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  def seed_all!
    SystemOperationsTeamSeeds::AGENT_SEEDS.each { |f| load_seed!(f) }
    load_seed!("system_agent_hierarchy.rb")
    load_seed!("system_operations_team_seed.rb")
  end

  let(:template) { Ai::TeamTemplate.global.find_by(slug: SystemOperationsTeamSeeds::TEMPLATE_SLUG) }
  let(:team)     { account.ai_agent_teams.find_by(template_id: template.id) }
  let(:root)     { Ai::Agent.global.find_by!(name: "System Concierge") }
  def reconciler = Ai::Teams::CanonicalTeamReconciler.new(account: account, template: template)

  it "is listed in SYSTEM_SEED_FILES after the hierarchy seed and before the governance reconcile" do
    listed = File.read(Rails.root.join("..", "extensions", "system", "server", "db", "seeds.rb"))[/SYSTEM_SEED_FILES\s*=\s*%w\[(.*?)\]/m, 1].split
    expect(listed).to include("system_operations_team_seed.rb")
    expect(listed.index("system_operations_team_seed.rb")).to be > listed.index("system_agent_hierarchy.rb")
    expect(listed.index("system_operations_team_seed.rb")).to be < listed.index("system_governance_policy_reconcile.rb")
  end

  it "seeds the System Operations template as a global, is_system, source_key-managed canonical" do
    seed_all!

    expect(template).to be_present
    expect(template).to be_global
    expect(template.is_system).to be true
    expect(template.source_key).to eq(SystemOperationsTeamSeeds::TEMPLATE_SLUG)
    expect(template.name).to eq("System Operations")
    expect(template.team_topology).to eq("hierarchical")
    expect(template.default_config).to include("coordination_strategy" => "manager_led",
                                               "communication_pattern" => "hub_spoke")
    expect(template.member_definitions.map { |d| d["agent_slug"] }).to eq(SystemOperationsTeamSeeds::ROSTER.keys)
    expect(template.manager_definition["agent_slug"]).to eq("system-concierge")
  end

  it "materialises the team on the admin account, System Concierge's principal as manager, every domain agent a member" do
    seed_all!

    expect(team).to be_present
    expect(team).to be_canonical
    expect(team.team_type).to eq("hierarchical")
    expect(team.team_topology).to eq("hierarchical")
    expect(team.coordination_strategy).to eq("manager_led")
    expect(team.communication_pattern).to eq("hub_spoke")

    members = team.members.includes(:agent).by_priority.to_a
    expect(members.map { |m| m.agent.cloned_from.slug }).to eq(SystemOperationsTeamSeeds::ROSTER.keys)
    expect(members.map(&:role)).to eq(SystemOperationsTeamSeeds::ROSTER.values.map(&:first))
    expect(members.map(&:is_lead)).to eq(SystemOperationsTeamSeeds::ROSTER.values.map(&:last))
    expect(members.map { |m| m.agent.account_id }.uniq).to eq([ account.id ])
    expect(members.map { |m| m.agent.global? }.uniq).to eq([ false ])
    expect(team.lead_agent.cloned_from_id).to eq(root.id)

    # Every member's canonical is a lineage child of System Concierge — the
    # forest HierarchyReconciler wrote — and the Concierge's delegation policy
    # admits every member type.
    policy = Ai::DelegationPolicy.resolve_for(agent_id: root.id, account_id: account.id)
    members.reject(&:is_lead).each do |m|
      canonical = m.agent.cloned_from
      expect(Ai::AgentLineage.for_child(canonical.id).active.pluck(:parent_agent_id)).to eq([ root.id ])
      expect(policy.allows_delegate_type?(canonical.agent_type)).to be true
    end
  end

  it "reports no drift on a fresh seed and is idempotent" do
    seed_all!

    expect(reconciler.drift).not_to be_drifted

    expect { load_seed!("system_operations_team_seed.rb") }
      .to not_change(Ai::TeamTemplate, :count)
      .and not_change(Ai::AgentTeam, :count)
      .and not_change(Ai::AgentTeamMember, :count)
      .and not_change(Ai::Agent, :count)
      .and not_change(Ai::AgentLineage, :count)
      .and not_change(Ai::DelegationPolicy, :count)
  end

  it "shows a removed lineage edge as team drift" do
    seed_all!
    sdwan = Ai::Agent.global.find_by!(slug: "sdwan-manager")
    Ai::AgentLineage.find_by!(parent_agent_id: root.id, child_agent_id: sdwan.id).terminate!(reason: "spec")

    report = reconciler.drift
    expect(report).to be_drifted
    expect(report.missing_edges).to eq([ "system-concierge/sdwan-manager" ])
  end

  it "shows a Concierge delegate type the team lacks as drift" do
    seed_all!
    policy = Ai::DelegationPolicy.resolve_for(agent_id: root.id, account_id: account.id)
    Ai::Agents::HierarchyWriter.new(account: account).ensure_delegation_policy!(
      agent: root, allowed_delegate_types: policy.allowed_delegate_types + [ "data_analyst" ]
    )

    report = reconciler.drift
    expect(report).to be_drifted
    expect(report.unrepresented_delegate_types).to eq([ "data_analyst" ])
  end

  it "repairs membership through the governance reconcile path" do
    seed_all!
    team.members.find_by(role: "executor").destroy!
    expect(reconciler.drift.missing_members.size).to eq(1)

    results = Ai::Teams::CanonicalTeamReconciler.reconcile_all!(account: account)
    expect(results.map { |r| r.template.slug }).to include(SystemOperationsTeamSeeds::TEMPLATE_SLUG)
    expect(reconciler.drift).not_to be_drifted
    expect(team.members.count).to eq(SystemOperationsTeamSeeds::ROSTER.size)
  end
end
