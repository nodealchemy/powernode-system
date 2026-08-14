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
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

sdwan_prompt = <<~PROMPT
  You are the **SDWAN Manager** — the overlay-network reconciler for the
  Powernode system extension. You own SDWAN peer health, topology compilation,
  BGP session health, VIP failover, route-policy audit, and operator-initiated
  SDWAN CRUD (networks, peers, firewall rules, access grants, user devices,
  federation peers).

  ## Charter

  You keep the live overlay consistent with intent: peers reachable and
  key-current, hubs reachable, iBGP sessions healthy, VIPs held by a live
  endpoint, route policies compiled correctly to FRR. Autonomous remediations
  (peer key rotation, BGP session restart, VIP failover) fire through the fleet
  sensor path; operator CRUD flows through your own approval queue (4h timeout)
  so network changes can be paused during a maintenance window without halting
  the rest of fleet autonomy.

  ## Operating Principles

  1. **Blast radius dictates posture.** A peer keypair rotation is low-risk
     (auto/notify); a VIP failover or a network delete is visible and gated —
     never failover or delete without the configured approval.
  2. **Compile, then apply.** Topology changes go through the compile pipeline
     (BGP/FRR, OVN, nftables) — reason about the compiled artifact, not the raw
     intent, before proposing an apply.
  3. **Stale ≠ broken.** A stale BGP observation is notification-only; don't
     restart a session you haven't confirmed is actually down.
  4. **Federation boundaries are contracts.** Treat federated peers' advertised
     subnets and access grants as authoritative; propose, don't silently
     override, cross-account routing.
  5. **Name the resource and the change.** Every plan cites the network/peer/VIP
     id, the observed vs desired state, and the specific remediation.
PROMPT

sdwan_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "SDWAN Manager",
  agent_type: "monitor",
  source_key: "sdwan-manager"
)
sdwan_agent.assign_attributes(
  description: "SDWAN reconciler — peer health, topology compilation, VIP failover, federation, BGP",
  status: "active",
  autonomy_config: { "interval_seconds" => 60, "extension" => "system", "scope" => "sdwan" }
)
# Persona prompt + reasoning-tier model (topology/BGP reasoning). system_prompt
# first (in-place into mcp_metadata), then a clean mcp_metadata reassignment so
# both persist. No hardcoded model id — AgentModelSelector resolves it.
sdwan_agent.system_prompt = sdwan_prompt
sdwan_agent.mcp_metadata = (sdwan_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "reasoning" } }
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
  # NOTE: The 7 autonomous SDWAN remediation actions (system.sdwan_peer_remediate,
  # system.sdwan_key_rotate, system.sdwan_failover, system.sdwan_user_device_revoke,
  # system.sdwan_bgp_session_remediate, system.sdwan_vip_failover,
  # system.sdwan_route_policy_audit) were MOVED to fleet_autonomy_agent.rb.
  # Those actions fire from FleetAutonomyService::SENSORS, whose tick! gates as
  # the "Fleet Autonomy" agent, so gate_action! resolves the policy against THAT
  # agent — seeding them here left them stranded (silently 'not_permitted') in
  # the sensor path. This mirrors the system.federation_peer_remediate move.
  # Only operator-initiated sdwan.* CRUD policies remain here.
  #
  # This table is seeded TWICE, against two different audiences (see the
  # operator upsert below): once agent-scoped, which is what an agent dispatch
  # resolves against, and once agent-less, which is what an operator HTTP
  # request resolves against. The verbs below are the single recorded intent for
  # both — do not fork them.

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

  # Access grants — granting access notifies, revoking requires approval.
  # Deleting is strictly more destructive than revoking: dependent: :destroy
  # cascades to every VPN device and their Vault keys, leaving nothing for the
  # 90-day audit window, so it is gated at least as tightly.
  "sdwan.access_grant_create"         => "notify_and_proceed",
  "sdwan.access_grant_revoke"         => "require_approval",
  "sdwan.access_grant_delete"         => "require_approval",

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

# IMP-187124ca2984 — the OPERATOR path needs its own rows.
#
# The upsert above scopes every row to this agent (ai_agent_id set), and
# Ai::InterventionPolicy#agent_matches? is
# `return true if ai_agent_id.nil?; agent_record && ai_agent_id == agent_record.id`.
# Ai::GatedActions#gate! passes no `agent:`, so an operator HTTP request through
# any of the SDWAN controllers matches NONE of them and falls through
# Ai::InterventionPolicyService to its require_approval default. The per-verb
# intent recorded above therefore bound only on the agent-dispatch path: every
# operator create/update/delete was hard-approval-gated by accident, not by
# decision.
#
# Mirroring the same table onto agent-less rows makes the recorded intent govern
# both audiences, and changes nothing about what any agent is allowed to do:
# since IMP-bfbf8052e179, `resolve` skips agent-less rows for an agent caller,
# so these rows bind exclusively on the operator path — an agent without its own
# row for a verb (Fleet Autonomy, Concierge, Topology Designer on sdwan.*) lands
# on the require_approval default, never here.
#
# CORRECTION (IMP-bfbf8052e179 follow-up, queued as IMP-d21b4c0cd5fd): the
# discriminator between the two audiences is `scope`, NOT ai_agent_id nil-ness.
# SCOPES = %w[global agent action_type]: these operator rows are
# scope "action_type" (upsert_operator_policies!), while scope "global" rows are
# agent-binding by design — db/seeds/system_manual_operation_policies.rb seeds
# global auto_approve for system.task.start/stop/restart/… and an operator's
# account-wide block row lives there too. The landed cut keys on ai_agent_id, so
# it over-catches those global rows: verified by execution, an agent resolving a
# global auto_approve row now gets require_approval (fail-safe) and a global
# block row no longer binds an agent at all (fail-OPEN). IMP-d21b4c0cd5fd
# narrows the cut to non-global agent-less rows; do not restate the ai_agent_id
# rationale here until it lands.
#
# Two further guards remain as defense in depth should the resolution contract
# ever regress: an agent-scoped row out-ranks these on specificity_score, and
# both sets carry the SAME trust_tier_minimum condition so an emergency trust
# demotion knocks out the agent row and this row together, preserving the
# escalation to require_approval.
#
# Note this is per-account: only accounts whose policies are seeded get the
# recorded intent. Any other account still lands on the require_approval
# default until an operator configures policies for it.
operator_count = System::Seeds::AgentSetupHelpers.upsert_operator_policies!(
  account: admin_account,
  definitions: sdwan_policies
)
System::Seeds::AgentSetupHelpers.clean_stale_operator_policies!(
  account: admin_account,
  keep_keys: sdwan_policies.keys,
  owned_prefixes: [ "sdwan." ]
)
puts "  ✅ SDWAN operator-path policies: #{operator_count} changed (#{sdwan_policies.size} total)"

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
  steps: [ {
    "name" => "SDWAN Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if sdwan_chain.new_record? || sdwan_chain.changed?
  sdwan_chain.save!
  puts "  ✅ SDWAN Manager Approval Chain: created/updated"
else
  puts "  ✅ SDWAN Manager Approval Chain: already up to date"
end
