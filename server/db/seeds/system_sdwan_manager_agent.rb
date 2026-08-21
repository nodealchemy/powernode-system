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
  # NOTE: 6 autonomous SDWAN remediation actions (system.sdwan_peer_remediate,
  # system.sdwan_key_rotate, system.sdwan_failover, system.sdwan_user_device_revoke,
  # system.sdwan_bgp_session_remediate, system.sdwan_vip_failover) were MOVED to
  # fleet_autonomy_agent.rb. Those actions fire from FleetAutonomyService::SENSORS,
  # whose tick! gates as the "Fleet Autonomy" agent, so gate_action! resolves the
  # policy against THAT agent — seeding them here left them stranded (silently
  # 'not_permitted') in the sensor path. This mirrors the
  # system.federation_peer_remediate move.
  #
  # IMP-17bc5546009a: a 7th, system.sdwan_route_policy_audit, moved alongside
  # them but was later DELETED outright (2026-08-21) — it had no sensor, no
  # DecisionEngine binding, and no executor, so it was a seeded no-op on either
  # agent. Not re-added here; see fleet_autonomy_agent.rb's history for the
  # removal.
  #
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

  # Access grants — granting FRESH access notifies, revoking requires approval.
  # Deleting is strictly more destructive than revoking: dependent: :destroy
  # cascades to every VPN device and their Vault keys, leaving nothing for the
  # 90-day audit window, so it is gated at least as tightly.
  #
  # IMP-343163bf37a4 splits REACTIVATION out of create. The grant is unique per
  # (network, user), so a "create" naming a user whose grant was revoked reuses
  # that row and clears its revocation — it is the inverse of the revoke above,
  # not an additive grant, and the "granting notifies" rationale never covered
  # it. notify_and_proceed executes inline (Ai::AutonomyGate treats it exactly
  # as auto_approve), so leaving reactivation under the create category would
  # have re-entered the revoked->active state with no human decision at all.
  # It therefore carries revoke's own tier.
  "sdwan.access_grant_create"         => "notify_and_proceed",
  "sdwan.access_grant_reactivate"     => "require_approval",
  "sdwan.access_grant_revoke"         => "require_approval",
  "sdwan.access_grant_delete"         => "require_approval",

  # User devices — issuing a VPN config notifies, revoking requires approval
  "sdwan.user_device_create"          => "notify_and_proceed",

  # Phase O6 write family (IMP-97c7b4123d8f). These shipped outside the
  # executor/gate regime entirely — direct model writes with no category, so
  # no tier was configurable at all.
  #
  # For the OVN family specifically, REST is read-only (routes.rb exposes only
  # index/show for ovn_deployments and no routes at all for switches, ports or
  # ACLs), so an agent held destructive reach a console operator did not have.
  # RESIDUAL, deliberately not closed here: host_bridges#destroy (which forces
  # release, skipping the drain window) and ipfix_collectors#update/#destroy
  # are REST writes that remain UNGATED, so for those two families the
  # asymmetry is now inverted rather than removed. Closing it belongs to the
  # per-family parity tasks that own those controllers.
  # Tiers follow the sibling precedent: creates and state transitions notify,
  # deletes require approval.
  #
  # Two deletes are sharper than their siblings and are called out rather than
  # left to the pattern: sdwan.ovn_deployment_delete removes the account's
  # whole OVN control plane (REST has no equivalent verb), and
  # sdwan.ovn_acl_delete retracts an isolation rule, which RELAXES multi-tenant
  # separation rather than merely removing a resource.
  "sdwan.host_bridge_create"          => "notify_and_proceed",
  "sdwan.host_bridge_update"          => "notify_and_proceed",
  "sdwan.host_bridge_delete"          => "require_approval",
  "sdwan.ovn_deployment_create"       => "notify_and_proceed",
  "sdwan.ovn_deployment_delete"       => "require_approval",
  "sdwan.ovn_logical_switch_create"   => "notify_and_proceed",
  "sdwan.ovn_logical_switch_update"   => "notify_and_proceed",
  "sdwan.ovn_logical_switch_delete"   => "require_approval",
  "sdwan.ovn_logical_switch_port_create" => "notify_and_proceed",
  "sdwan.ovn_logical_switch_port_update" => "notify_and_proceed",
  "sdwan.ovn_logical_switch_port_delete" => "require_approval",
  "sdwan.ovn_acl_create"              => "notify_and_proceed",
  "sdwan.ovn_acl_delete"              => "require_approval",
  "sdwan.ipfix_collector_create"      => "notify_and_proceed",
  "sdwan.ipfix_collector_delete"      => "require_approval",

  # Federation — cross-instance peering is always sensitive
  "sdwan.federation_peer_propose"     => "require_approval",
  "sdwan.federation_peer_accept"      => "require_approval",
  "sdwan.federation_peer_revoke"      => "require_approval",

  # IMP-9bf58a693634 — data_residency is a compliance DECLARATION, not a
  # label: Federation::ResidencyEnforcer gates cross-boundary record homing on
  # it and Sdwan::FederationGovernance raises a finding on an active platform
  # peer that has not declared one. Rewriting it relaxes or fabricates a
  # regulatory boundary, so it carries the tier of the three trust-boundary
  # verbs above rather than the notify_and_proceed the other peer-field edits
  # take — notify_and_proceed executes INLINE (Ai::AutonomyGate treats it
  # exactly as auto_approve), which for this field would have bought an audit
  # row and no human decision at all.
  "sdwan.federation_peer_data_residency" => "require_approval"
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
# Mirroring the same table onto operator-path rows makes the recorded intent
# govern both audiences, and changes nothing about what any agent is allowed to
# do: `resolve` skips scope-"action_type" rows for an agent caller, so these
# rows bind exclusively on the operator path — an agent without its own row for
# a verb (Fleet Autonomy, Concierge, Topology Designer on sdwan.*) lands on the
# require_approval default, never here.
#
# The discriminator is `scope`, NOT ai_agent_id nil-ness (IMP-cb36021d4094,
# landed; it superseded the duplicate IMP-d21b4c0cd5fd). SCOPES =
# %w[global agent action_type] names THREE audiences: these operator rows are
# scope "action_type" (upsert_operator_policies!), while scope "global" rows are
# agent-binding by design — server/db/seeds/autonomy_data_seed.rb seeds
# status_update/proposal/escalation there and Ai::AgentOutreachService resolves
# them with an agent always set. IMP-bfbf8052e179's cut keyed on ai_agent_id and
# so over-caught the global audience: measured, an agent resolving a global
# auto_approve row got require_approval (fail-safe) and a global block row
# stopped binding an agent at all (fail-OPEN, since require_approval is not a
# denial — the gate parks it for an approval any active user may grant).
#
# Two further guards remain as defense in depth should the resolution contract
# ever regress: an agent-scoped row out-ranks these on specificity_key at ANY
# priority, since that key is lexicographic and the agent tier sits above the
# agent-less one (IMP-6430e3a8c4a1 — while it was an additive score, this
# out-ranking held only because of the priority gap seeded below), and
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
