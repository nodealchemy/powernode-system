# frozen_string_literal: true

require "rails_helper"

# Pins the per-agent enhancement contract for the system extension's agents:
#   - every seeded agent carries a non-empty persona system_prompt, and
#   - the reasoning-heavy agents request a reasoning-tier model via
#     model_requirements (NOT a hardcoded model id), while the high-frequency
#     monitors stay on the default tier (no reasoning pin, no hardcoded id).
RSpec.describe "system agents persona + model tier" do
  AGENT_SEED_FILES = %w[
    fleet_autonomy_agent.rb
    system_concierge_agent.rb
    system_runtime_manager_agent.rb
    system_cve_responder_agent.rb
    system_disk_image_manager_agent.rb
    system_sdwan_manager_agent.rb
    system_topology_designer_agent.rb
    system_gitops_reconciler_agent.rb
  ].freeze

  ALL_AGENTS = [
    "Fleet Autonomy", "System Concierge", "Runtime Manager", "CVE Responder",
    "Disk Image Manager", "SDWAN Manager", "System Topology Designer",
    "GitOps Reconciler"
  ].freeze

  # Agents that should request a reasoning-tier model (security / operator /
  # topology / declarative-diff reasoning).
  REASONING_AGENTS = [
    "CVE Responder", "SDWAN Manager", "System Concierge",
    "System Topology Designer", "GitOps Reconciler"
  ].freeze

  # High-frequency monitors that stay on the default tier (cost-sensitive ticks).
  STANDARD_AGENTS = [ "Fleet Autonomy", "Runtime Manager", "Disk Image Manager" ].freeze

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  before do
    silence_warnings do
      AGENT_SEED_FILES.each do |file|
        load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
      end
    end
  end

  def agent(name)
    Ai::Agent.find_by!(account: account, name: name)
  end

  it "seeds all 8 system agents" do
    expect(Ai::Agent.where(account: account, name: ALL_AGENTS).count).to eq(ALL_AGENTS.size)
  end

  it "gives every system agent a non-empty persona system_prompt" do
    empty = ALL_AGENTS.reject { |n| agent(n).system_prompt.to_s.strip.present? }
    expect(empty).to be_empty, "agents missing a system_prompt: #{empty.inspect}"
  end

  it "never pins a hardcoded model id (resolution stays with AgentModelSelector)" do
    pinned = ALL_AGENTS.select { |n| agent(n).mcp_metadata.dig("model_config", "model").present? }
    expect(pinned).to be_empty, "agents with a hardcoded model id: #{pinned.inspect}"
  end

  it "requests reasoning-tier model_requirements for the reasoning agents" do
    REASONING_AGENTS.each do |name|
      tier = agent(name).mcp_metadata.dig("model_config", "model_requirements", "tier")
      expect(tier).to eq("reasoning"), "#{name} should request reasoning tier, got #{tier.inspect}"
    end
  end

  it "leaves the high-frequency monitors on the default (non-reasoning) tier" do
    STANDARD_AGENTS.each do |name|
      tier = agent(name).mcp_metadata.dig("model_config", "model_requirements", "tier")
      expect(tier).not_to eq("reasoning"), "#{name} should stay on the default tier"
    end
  end
end
