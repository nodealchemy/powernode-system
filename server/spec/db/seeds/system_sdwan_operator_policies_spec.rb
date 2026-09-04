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
# The SAME per-verb table is declared at both shapes (POLICY_SETS
# "sdwan-manager" at the agent shape, "sdwan-operator" at scope
# "action_type"), so one recorded intent governs both audiences — and ONE
# writer, System::Governance::PolicyReconciler, writes both (proposal §5
# ruling 7, IMP-10e4f6c3bcd2); the agent seed writes identity, chain and trust
# only. Every example below runs the seed AND the reconciler, as a boot does.
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

  def reconcile!
    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!
  end

  before do
    load_sdwan_seed!
    reconcile!
  end

  # The account's ACTING principal for the canonical (HIER-P2I) — the row the
  # reconciler writes against and the gate reads.
  let(:sdwan_agent) { System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: "sdwan-manager") }
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
      # Tightened 2026-08-28: it was the only destructive verb of 14 that
      # proceeded unattended, and deleting a mapping is an ingress outage.
      "sdwan.port_mapping_delete"     => "require_approval",
      # IMP-97c7b4123d8f — the Phase O6 write family, which shipped with no
      # category at all. Deletes require approval like every sibling; the two
      # sharpest are ovn_deployment_delete (removes the account's whole OVN
      # control plane, with no REST equivalent) and ovn_acl_delete (retracts a
      # multi-tenant isolation rule).
      "sdwan.host_bridge_create"      => "notify_and_proceed",
      "sdwan.host_bridge_update"      => "notify_and_proceed",
      "sdwan.host_bridge_delete"      => "require_approval",
      "sdwan.ovn_deployment_create"   => "notify_and_proceed",
      "sdwan.ovn_deployment_delete"   => "require_approval",
      "sdwan.ovn_logical_switch_create" => "notify_and_proceed",
      "sdwan.ovn_logical_switch_update" => "notify_and_proceed",
      "sdwan.ovn_logical_switch_delete" => "require_approval",
      "sdwan.ovn_logical_switch_port_create" => "notify_and_proceed",
      "sdwan.ovn_logical_switch_port_update" => "notify_and_proceed",
      "sdwan.ovn_logical_switch_port_delete" => "require_approval",
      "sdwan.ovn_acl_create"          => "notify_and_proceed",
      "sdwan.ovn_acl_delete"          => "require_approval",
      "sdwan.ipfix_collector_create"  => "notify_and_proceed",
      # IMP-6bbe5c673c38 — the state toggle sits with the other state
      # transitions. It must stay STRICTLY cheaper than the delete beside it:
      # disable keeps the row and its flow samples, delete cascades them, and
      # tiering the safe verb no lower than the destructive one is what pushes
      # a caller toward the destructive one.
      "sdwan.ipfix_collector_update"  => "notify_and_proceed",
      "sdwan.ipfix_collector_delete"  => "require_approval",
      "sdwan.access_grant_create"     => "notify_and_proceed",
      # IMP-343163bf37a4: reactivation is the inverse of the revoke below, not
      # an additive grant, so it carries the revoke's tier rather than the
      # create's. notify_and_proceed executes inline (Ai::AutonomyGate treats
      # it as auto_approve), so this row is the whole difference between a
      # resurrection an operator decides and one that merely gets logged.
      "sdwan.access_grant_reactivate" => "require_approval",
      "sdwan.access_grant_revoke"     => "require_approval",
      "sdwan.access_grant_delete"     => "require_approval",
      "sdwan.user_device_create"      => "notify_and_proceed",
      "sdwan.federation_peer_propose" => "require_approval",
      "sdwan.federation_peer_accept"  => "require_approval",
      "sdwan.federation_peer_revoke"  => "require_approval"
    }
  end

  it "writes an active agent-less policy for every recorded SDWAN verb" do
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

  # IMP-bfbf8052e179 — the operator rows must bind the operator audience ONLY.
  # agent_matches? admits a nil-agent row for any caller, and resolve used to
  # prefer agent-scoped rows only when the calling agent HAD matching ones — so
  # an agent that carries NO sdwan.* rows of its own (Fleet Autonomy,
  # Concierge, Topology Designer) at normal tier caught these operator rows and
  # dropped from the require_approval default to notify_and_proceed on writes
  # like port-mapping create/delete and VPN-device minting.
  #
  # What makes these rows operator-only is their SCOPE, not their nil
  # ai_agent_id (IMP-cb36021d4094): resolution drops the scope-"action_type"
  # audience for an agent caller, which is the scope the "sdwan-operator" set
  # is declared at. A scope-"global" row would still bind this agent.
  it "keeps an unrelated monitored-tier agent on the require_approval default" do
    other_agent = create(:ai_agent, account: account, provider: provider,
                         name: "Unrelated Fleet Agent")
    create(:ai_agent_trust_score, :monitored, account: account, agent: other_agent)

    %w[sdwan.port_mapping_create sdwan.port_mapping_delete sdwan.user_device_create]
      .each do |category|
      result = service.resolve(action_category: category, agent: other_agent)

      expect(result[:policy]).to eq("require_approval"),
                                 "#{category} resolved to #{result[:policy]} for an unrelated agent"
      expect(result[:record]).to be_nil,
                                 "an operator row bound an unrelated agent on #{category}"
    end
  end

  # An agent caller never sees a scope-"action_type" row, so the demotion
  # escalation holds structurally. The shared trust_tier_minimum condition on
  # both row sets stays as defense in depth — if the resolution-level audience
  # split ever regressed, conditions_met? would still stop a demoted agent from
  # landing on the operator row.
  it "still escalates a demoted agent instead of catching it on the operator row" do
    Ai::AgentTrustScore.find_by!(agent_id: sdwan_agent.id).emergency_demote!(reason: "spec")

    result = service.resolve(action_category: "sdwan.peer_create", agent: sdwan_agent.reload)

    expect(result[:policy]).to eq("require_approval")
    expect(result[:record]).to be_nil,
                               "the operator-path row became a fallback for an emergency-demoted agent"
  end

  # Defense in depth. InterventionPolicyService#resolve keeps the
  # scope-"action_type" audience away from an agent caller (IMP-cb36021d4094),
  # but the agent row must also out-rank the operator row on specificity_key,
  # which is what decides `matching.max_by(&:specificity_key)` if that
  # restriction ever goes away — and what already decides it against the
  # scope-"global" rows an agent caller DOES see.
  #
  # Asserted at a priority the seed would never write, because that key is
  # lexicographic (IMP-6430e3a8c4a1): the agent tier out-ranks the agent-less
  # one whatever priorities the two rows carry. While it was an additive score
  # the agent row's edge was a mere +5, so this held only by the seeded 10-vs-5
  # gap and an operator raising the operator set by 6 would have inverted it.
  it "ranks the agent-scoped row above the operator row on specificity alone" do
    category = "sdwan.peer_create"
    agent_row    = Ai::InterventionPolicy.find_by!(account: account, action_category: category,
                                                   ai_agent_id: sdwan_agent.id)
    operator_row = Ai::InterventionPolicy.find_by!(account: account, action_category: category,
                                                   ai_agent_id: nil)

    expect(agent_row.specificity_key <=> operator_row.specificity_key).to eq(1)

    # In memory only — the seeded rows are untouched for the idempotence example.
    operator_row.priority = agent_row.priority + 100
    expect(agent_row.specificity_key <=> operator_row.specificity_key).to eq(1),
                                                                         "priority out-ranked the scope tier — IMP-6430e3a8c4a1 regressed"
  end

  # A seed re-run (targeted, on an established install) and a second
  # reconcile pass must change nothing: the seed writes no row, the reconciler
  # creates absence only.
  it "is idempotent across a re-run of the seed and the reconciler" do
    expect { load_sdwan_seed!; reconcile! }
      .not_to change { Ai::InterventionPolicy.where(account: account).order(:action_category, :ai_agent_id).pluck(:action_category, :ai_agent_id, :policy) }
  end
end
