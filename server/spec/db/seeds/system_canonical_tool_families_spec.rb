# frozen_string_literal: true

require "rails_helper"
require "digest"

# IMP-777f59d4cc1e — the system extension's canonicals that seeded no tool
# access (CVE Responder, Fleet Autonomy, Infrastructure Generalist, Runtime
# Manager, SDWAN Manager) exported the platform read-verb fallback, the same
# list for every agent, so their skeletons were identical in what they could
# reach. Each now declares tool families derived from its duty surface.
RSpec.describe "system extension canonical agent seeds declare tool families" do
  seeds = {
    "cve-responder" => "system_cve_responder_agent.rb",
    "fleet-autonomy" => "fleet_autonomy_agent.rb",
    "infrastructure-generalist" => "system_concierge_agent.rb",
    "runtime-manager" => "system_runtime_manager_agent.rb",
    "sdwan-manager" => "system_sdwan_manager_agent.rb"
  }.freeze

  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }
  let(:registry)  { Ai::ClaudeExport::ToolAllowlist::Registry.snapshot }

  before { seeds.each_value { |file| load_seed!(file) } }

  def agent(slug)
    Ai::Agent.global.find_by!(slug: slug)
  end

  it "declares tool families on each of them" do
    unscoped = seeds.keys.reject { |slug| agent(slug).mcp_metadata.dig("tool_access", "tool_families").present? }

    expect(unscoped).to be_empty, "these canonicals seed no tool families: #{unscoped.join(', ')}"
  end

  it "resolves each to its own scoped allowlist — not the read-verb fallback, not the full catalog" do
    resolved = seeds.keys.to_h { |slug| [ slug, Ai::ClaudeExport::ToolAllowlist.platform_actions_for(agent(slug), registry: registry) ] }

    expect(resolved.values).not_to include(Ai::ClaudeExport::ToolAllowlist::UNSCOPED)
    fallback = resolved.select { |_, actions| actions.sort == registry.read_action_names.sort }.keys
    expect(fallback).to be_empty, "these canonicals still export the read-verb fallback: #{fallback.join(', ')}"
    expect(resolved.values.map { |actions| Digest::SHA256.hexdigest(actions.sort.join(",")) }.uniq.size).to eq(seeds.size)
  end

  it "keeps the Infrastructure Generalist's Claude Code surface read-only apart from delegation" do
    actions = Ai::ClaudeExport::ToolAllowlist.platform_actions_for(agent("infrastructure-generalist"), registry: registry)
    writes = actions - registry.read_action_names

    expect(writes).to eq(%w[execute_agent])
  end
end
