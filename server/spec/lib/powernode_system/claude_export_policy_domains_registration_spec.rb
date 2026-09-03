# frozen_string_literal: true

require "rails_helper"

# HIER-P2F (HIER-P1B open question) — the extension REGISTERS its
# System::AutonomyActions::DOMAIN_PREFIXES with core's
# Ai::ClaudeExport::PolicyDomains at boot, so the Claude Code exporter and the
# router derive an agent's policy domains from the real table instead of the
# leading-token heuristic ("system.instance_pool_replenish" -> "instance").
RSpec.describe "PowernodeSystem Claude-export policy domain registration", type: :lib do
  let(:prefixes) { System::AutonomyActions::DOMAIN_PREFIXES }

  it "registers every DOMAIN_PREFIXES entry, once, in the table's (first-match-wins) order" do
    registered = Ai::ClaudeExport::PolicyDomains.registered
    expect(registered.map(&:first)).to eq(prefixes.keys)
    expect(registered.to_h).to eq(prefixes.transform_values { |v| v.map(&:to_s) })
  end

  it "resolves the registered domains where the heuristic would guess wrong" do
    domains = Ai::ClaudeExport::PolicyDomains
    expect(domains.domain_for("system.instance_pool_replenish")).to eq("instance_pool")
    expect(domains.domain_for("system.sdwan_federation_compose")).to eq("topology")
    expect(domains.domain_for("system.multi_tenant_isolation")).to eq("topology")
    expect(domains.domain_for("system.module_critical_upgrade_ready")).to eq("cve")
    expect(domains.domain_for("system.restore_volume")).to eq("storage")
    expect(domains.domain_for("system.runtime_docker_provision")).to eq("container_runtime")
    expect(domains.domain_for("system.disk_image_publication_promote")).to eq("disk_image")
    expect(domains.domain_for("system.gitops_apply_proposal")).to eq("gitops")
  end

  it "gives the Topology Designer's exported description its `topology` trigger (account scope)" do
    domains = Ai::ClaudeExport::PolicyDomains.for_categories(
      System::Governance::PolicyDeclarations::TOPOLOGY_DESIGNER_POLICIES.keys
    )
    expect(domains).to eq(%w[topology])

    agent = build(:ai_agent, name: "System Topology Designer", agent_type: "assistant",
                              description: "Cross-cutting topology design and composition.")
    description = Ai::ClaudeExport::RoutingDescription.build(
      agent, skills: [], domains: domains,
      siblings: [ { key: "sdwan-manager", name: "SDWAN Manager", domains: %w[sdwan], agent_type: "monitor" } ]
    )
    expect(description).to start_with("Use this agent when the task involves topology")
  end
end
