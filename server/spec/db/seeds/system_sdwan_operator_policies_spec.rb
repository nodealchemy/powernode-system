# frozen_string_literal: true

require "rails_helper"

# IMP-187124ca2984 — the operator-path policy ruling.
#
# `Ai::GatedActions#gate!` never passes `agent:`, so every operator HTTP request
# resolves with `agent = nil`. `Ai::InterventionPolicy#agent_matches?` is
# `return true if ai_agent_id.nil?; agent_record && ai_agent_id == agent_record.id`
# — an agent-SCOPED row can therefore never match an agent-less caller. The SDWAN
# Manager's carefully recorded per-verb intent (notify_and_proceed on low-risk
# creates, require_approval on deletes) bound only on the agent-dispatch path,
# and every gated operator request fell through InterventionPolicyService to its
# require_approval default instead. Wiring the remaining create/update executors
# on top of that would have shipped maximal friction by accident.
#
# The seed now mirrors the SAME per-verb table onto agent-less rows, so one
# recorded intent governs both audiences.
RSpec.describe "SDWAN operator-path intervention policies" do
  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  def load_sdwan_seed!
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds",
                           "system_sdwan_manager_agent.rb")
    end
  end

  before { load_sdwan_seed! }

  let(:sdwan_agent) { Ai::Agent.global.find_by!(name: "SDWAN Manager") }
  let(:service)     { Ai::InterventionPolicyService.new(account: account) }

  # The recorded per-verb intent, restated independently of the seed so a
  # silent edit to the table shows up as a failing expectation rather than as a
  # change in what an operator experiences.
  let(:operator_verbs) do
    {
      "sdwan.network_create"          => "notify_and_proceed",
      "sdwan.network_update"          => "notify_and_proceed",
      "sdwan.network_delete"          => "require_approval",
      "sdwan.peer_create"             => "notify_and_proceed",
      "sdwan.peer_update"             => "notify_and_proceed",
      "sdwan.peer_delete"             => "require_approval",
      "sdwan.firewall_rule_create"    => "notify_and_proceed",
      "sdwan.firewall_rule_update"    => "notify_and_proceed",
      "sdwan.firewall_rule_delete"    => "require_approval",
      "sdwan.virtual_ip_create"       => "notify_and_proceed",
      "sdwan.virtual_ip_update"       => "notify_and_proceed",
      "sdwan.virtual_ip_delete"       => "require_approval",
      "sdwan.route_policy_create"     => "notify_and_proceed",
      "sdwan.route_policy_update"     => "notify_and_proceed",
      "sdwan.route_policy_delete"     => "require_approval",
      "sdwan.port_mapping_create"     => "notify_and_proceed",
      "sdwan.port_mapping_update"     => "notify_and_proceed",
      "sdwan.port_mapping_delete"     => "notify_and_proceed",
      "sdwan.access_grant_create"     => "notify_and_proceed",
      "sdwan.access_grant_revoke"     => "require_approval",
      "sdwan.access_grant_delete"     => "require_approval",
      "sdwan.user_device_create"      => "notify_and_proceed",
      "sdwan.federation_peer_propose" => "require_approval",
      "sdwan.federation_peer_accept"  => "require_approval",
      "sdwan.federation_peer_revoke"  => "require_approval"
    }
  end

  it "seeds an active agent-less policy for every recorded SDWAN verb" do
    missing = operator_verbs.keys.reject do |category|
      Ai::InterventionPolicy.exists?(
        account: account, ai_agent_id: nil, action_category: category, is_active: true
      )
    end

    expect(missing).to be_empty,
                       "no operator-path (agent-less) policy seeded for: #{missing.inspect}"
  end

  # The behavioral oracle. Row existence is not the claim — what an agent-less
  # caller RESOLVES to is, because that is what Ai::AutonomyGate branches on.
  it "resolves every verb to its recorded policy for an agent-less operator caller" do
    resolved = operator_verbs.keys.index_with do |category|
      service.resolve(action_category: category, agent: nil)[:policy]
    end

    expect(resolved).to eq(operator_verbs)
  end

  # Non-vacuity control: the change must be per-verb, not a blanket lowering of
  # the operator path. system.sdwan_vip_failover is gated on an operator route
  # (virtual_ips_controller#failover) but belongs to Fleet Autonomy's table, so
  # it is deliberately absent here and must still land on the default.
  it "leaves a category outside the table on the require_approval default" do
    result = service.resolve(action_category: "system.sdwan_vip_failover", agent: nil)

    expect(result[:policy]).to eq("require_approval")
    expect(result[:record]).to be_nil, "an operator policy leaked outside the seeded table"
  end

  # The two audiences must stay separate: adding operator rows must not displace
  # the SDWAN Manager's own policy on the agent-dispatch path.
  it "still resolves the agent-dispatch path against the SDWAN Manager's own rows" do
    displaced = operator_verbs.keys.reject do |category|
      service.resolve(action_category: category, agent: sdwan_agent)[:record]&.ai_agent_id == sdwan_agent.id
    end

    expect(displaced).to be_empty,
                         "operator rows displaced the agent-scoped policy for: #{displaced.inspect}"
  end

  # An agent-less row is not operator-only: agent_matches? admits it for ANY
  # caller, so it also sits under the SDWAN Manager as a fallback. The
  # agent-scoped rows are conditioned on trust_tier_minimum "monitored", which
  # is what makes an emergency demotion escalate — conditions_met? stops
  # matching them and resolution falls to the require_approval default. An
  # unconditioned operator row would have caught that fall and kept a demoted
  # agent on notify_and_proceed, quietly disarming the demotion.
  it "still escalates a demoted agent instead of catching it on the operator row" do
    Ai::AgentTrustScore.find_by!(agent_id: sdwan_agent.id).emergency_demote!(reason: "spec")

    result = service.resolve(action_category: "sdwan.peer_create", agent: sdwan_agent.reload)

    expect(result[:policy]).to eq("require_approval")
    expect(result[:record]).to be_nil,
                               "the operator-path row became a fallback for an emergency-demoted agent"
  end

  # Defense in depth. InterventionPolicyService#resolve prefers agent-scoped
  # matches explicitly (`agent_scoped = matching.select { ... }`), but that is
  # only one of the two things keeping the audiences apart: the agent row must
  # also out-rank the operator row on specificity_score, which is what decides
  # `matching.max_by(&:specificity_score)` if that preference ever goes away.
  it "ranks the agent-scoped row above the operator row on specificity alone" do
    category = "sdwan.peer_create"
    agent_row    = Ai::InterventionPolicy.find_by!(account: account, action_category: category,
                                                   ai_agent_id: sdwan_agent.id)
    operator_row = Ai::InterventionPolicy.find_by!(account: account, action_category: category,
                                                   ai_agent_id: nil)

    expect(agent_row.specificity_score).to be > operator_row.specificity_score
  end

  # Seeds are re-run on every deploy. The operator set and the agent set each
  # carry their own stale cleanup, and neither may eat the other's rows.
  it "is idempotent across a re-run" do
    expect { load_sdwan_seed! }
      .not_to change { Ai::InterventionPolicy.where(account: account).order(:action_category, :ai_agent_id).pluck(:action_category, :ai_agent_id, :policy) }
  end
end
