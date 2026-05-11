# frozen_string_literal: true

# Seeds the SDWAN Manager AI agent + per-action policies + dedicated approval
# chain. Carved out of Fleet Autonomy (2026-05-10) so SDWAN operations have
# their own intervention queue + can be paused independently during network
# maintenance windows without halting fleet operations.
#
# Covers: networks, peers, firewall rules, VIPs, route policies, port mappings,
# access grants, user devices, federation peers — both autonomous (BGP /
# topology remediation) and operator-initiated (delete network, revoke peer).

puts "\n  Seeding SDWAN Manager agent + policies..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping SDWAN Manager seed"
  return
end

def ensure_sdwan_trust_score!(account, agent)
  return if Ai::AgentTrustScore.exists?(agent_id: agent.id)

  Ai::AgentTrustScore.create!(
    account: account, agent: agent, tier: "monitored",
    reliability: 0.7, cost_efficiency: 0.7, safety: 0.85,
    quality: 0.7, speed: 0.7, overall_score: 0.74
  )
end

def upsert_sdwan_policies!(account, agent, policies)
  return 0 unless agent

  changed = 0
  policies.each do |action_category, policy_type|
    policy = Ai::InterventionPolicy.find_or_initialize_by(
      account: account,
      action_category: action_category,
      scope: "agent",
      ai_agent_id: agent.id
    )
    policy.assign_attributes(
      policy: policy_type,
      priority: 10,
      is_active: true,
      conditions: { "trust_tier_minimum" => "monitored" },
      preferred_channels: %w[notification]
    )
    if policy.new_record? || policy.changed?
      policy.save!
      changed += 1
    end
  end
  changed
end

creator  = admin_account.users.find_by(email: "admin@powernode.org") || admin_account.users.first
provider = ::Ai::Provider.first
unless creator && provider
  puts "  ⚠️  Need at least one user + Ai::Provider before seeding SDWAN Manager — skipping"
  return
end

sdwan_agent = admin_account.ai_agents.find_or_initialize_by(
  name: "SDWAN Manager",
  agent_type: "monitor"
)
sdwan_agent.assign_attributes(
  description: "SDWAN reconciler — peer health, topology compilation, VIP failover, federation, BGP",
  status: "active",
  autonomy_config: { "interval_seconds" => 60, "extension" => "system", "scope" => "sdwan" }
)
if sdwan_agent.new_record?
  sdwan_agent.creator  = creator
  sdwan_agent.provider = provider
end
sdwan_agent.save!
ensure_sdwan_trust_score!(admin_account, sdwan_agent)
puts "  ✅ SDWAN Manager agent: #{sdwan_agent.previously_new_record? ? 'created' : 'updated'}"

# Action category registration happens in System::Engine#after_initialize so
# validation passes when these policies are created.

sdwan_policies = {
  # Existing autonomous actions (carried over from Fleet Autonomy)
  "system.sdwan_peer_remediate"        => "notify_and_proceed",
  "system.sdwan_key_rotate"            => "auto_approve",
  "system.sdwan_failover"              => "require_approval",
  "system.sdwan_user_device_revoke"    => "require_approval",
  "system.sdwan_bgp_session_remediate" => "notify_and_proceed",
  "system.sdwan_vip_failover"          => "require_approval",
  "system.sdwan_route_policy_audit"    => "auto_approve",

  # Operator-initiated network ops (newly gated 2026-05-10)
  "sdwan.network_create"              => "notify_and_proceed",
  "sdwan.network_update"              => "notify_and_proceed",
  "sdwan.network_delete"              => "require_approval",

  # Peer ops — destroy revokes a node's network membership
  "sdwan.peer_create"                 => "notify_and_proceed",
  "sdwan.peer_update"                 => "notify_and_proceed",
  "sdwan.peer_delete"                 => "require_approval",

  # Firewall rules — additive auto, removal/edit notify
  "sdwan.firewall_rule_create"        => "notify_and_proceed",
  "sdwan.firewall_rule_update"        => "notify_and_proceed",
  "sdwan.firewall_rule_delete"        => "require_approval",

  # VIPs — create/update notify, destroy + manual failover require approval
  "sdwan.virtual_ip_create"           => "notify_and_proceed",
  "sdwan.virtual_ip_update"           => "notify_and_proceed",
  "sdwan.virtual_ip_delete"           => "require_approval",

  # Route policies — additive notify, destructive require approval
  "sdwan.route_policy_create"         => "notify_and_proceed",
  "sdwan.route_policy_update"         => "notify_and_proceed",
  "sdwan.route_policy_delete"         => "require_approval",

  # Port mappings — DNAT, generally low-risk
  "sdwan.port_mapping_create"         => "notify_and_proceed",
  "sdwan.port_mapping_update"         => "notify_and_proceed",
  "sdwan.port_mapping_delete"         => "notify_and_proceed",

  # Access grants — granting access notifies, revoking requires approval
  "sdwan.access_grant_create"         => "notify_and_proceed",
  "sdwan.access_grant_revoke"         => "require_approval",

  # User devices — issuing a VPN config notifies, revoking requires approval
  "sdwan.user_device_create"          => "notify_and_proceed",

  # Federation — cross-instance peering is always sensitive
  "sdwan.federation_peer_propose"     => "require_approval",
  "sdwan.federation_peer_accept"      => "require_approval",
  "sdwan.federation_peer_revoke"      => "require_approval"
}

count = upsert_sdwan_policies!(admin_account, sdwan_agent, sdwan_policies)
puts "  ✅ SDWAN Manager policies: #{count} created/updated (#{sdwan_policies.size} total)"

stale = Ai::InterventionPolicy
  .where(account: admin_account, ai_agent_id: sdwan_agent.id, scope: "agent")
  .where.not(action_category: sdwan_policies.keys)
if stale.any?
  stale_count = stale.count
  stale.destroy_all
  puts "  🧹 Cleaned #{stale_count} stale SDWAN Manager policies"
end

sdwan_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "SDWAN Manager Actions"
)
sdwan_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 4,
  steps: [{
    "name" => "SDWAN Operator Approval",
    "approvers" => [{ "type" => "permission", "value" => "system.infra_tasks.control" }],
    "required_approvals" => 1
  }]
)
if sdwan_chain.new_record? || sdwan_chain.changed?
  sdwan_chain.save!
  puts "  ✅ SDWAN Manager Approval Chain: created/updated"
else
  puts "  ✅ SDWAN Manager Approval Chain: already up to date"
end
