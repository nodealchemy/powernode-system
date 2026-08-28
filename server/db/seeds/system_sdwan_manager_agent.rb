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

# Declared set now lives in System::Governance::PolicyDeclarations so the reconciler can
# assert it against a RUNNING database without executing this seed.
sdwan_policies = System::Governance::PolicyDeclarations::SDWAN_MANAGER_POLICIES

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
