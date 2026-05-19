# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the SDWAN Manager AI agent + per-action policies + dedicated approval
# chain. Carved out of Fleet Autonomy (2026-05-10) so SDWAN operations have
# their own intervention queue + can be paused independently during network
# maintenance windows without halting fleet operations.
#
# Covers: networks, peers, firewall rules, VIPs, route policies, port mappings,
# access grants, user devices, federation peers — both autonomous (BGP /
# topology remediation) and operator-initiated (delete network, revoke peer).

puts "\n  Seeding SDWAN Manager agent + policies..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: ["anthropic", "openai"]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

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
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: sdwan_agent,
  tier: "trusted", overall: 0.78,
  dimensions: {
    reliability: 0.75, cost_efficiency: 0.75, safety: 0.88, quality: 0.75, speed: 0.75
  }
)
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

count = System::Seeds::AgentSetupHelpers.upsert_policies!(
  account: admin_account, agent: sdwan_agent,
  definitions: sdwan_policies
)
System::Seeds::AgentSetupHelpers.clean_stale_policies!(
  account: admin_account, agent: sdwan_agent,
  keep_keys: sdwan_policies.keys
)
puts "  ✅ SDWAN Manager policies: #{count} changed (#{sdwan_policies.size} total)"

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
