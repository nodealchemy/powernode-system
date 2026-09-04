# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the SDWAN Manager AI agent + dedicated approval chain. Carved out of Fleet Autonomy (2026-05-10) so SDWAN operations have
# their own intervention queue + can be paused independently during network
# maintenance windows without halting fleet operations.
#
# Covers: networks, peers, firewall rules, VIPs, route policies, port mappings,
# access grants, user devices, federation peers — both autonomous (BGP /
# topology remediation) and operator-initiated (delete network, revoke peer).

puts "\n  Seeding SDWAN Manager agent..."

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

# ── Intervention policies: NOT written here ──────────────────────────────
# System::Governance::PolicyReconciler is the SINGLE WRITER of the declared
# set (PolicyDeclarations::SDWAN_MANAGER_POLICIES, POLICY_SETS "sdwan-manager") —
# on every boot, the first one included (rails-start.sh runs the governance
# reconcile after db:seed), and via `rails system:governance:reconcile`. It
# writes against the account's acting principal for this agent (HIER-P2I)
# and creates absence only, so an operator's tuned verb survives a re-seed.
# The approval chain below stays here: the reconciler writes policy rows and
# nothing else. Proposal §5 ruling 7 / IMP-10e4f6c3bcd2.
# TWO sets, two audiences (HIER-P2A, IMP-187124ca2984). The AGENT set is the
# 43 `sdwan.*` operator CRUD keys plus the 14 sensor-routed `system.sdwan_*`
# / `system.federation_*` remediations the fleet tick gates under THIS
# agent. The OPERATOR-path twin (SDWAN_OPERATOR_POLICIES, POLICY_SETS
# "sdwan-operator", scope "action_type") mirrors the 43 CRUD verbs for an
# agent-less caller — `Ai::GatedActions#gate!` passes no `agent:`, and an
# agent-scoped row can never match one — while `InterventionPolicyService
# #resolve` drops that audience for an agent caller (IMP-cb36021d4094), so
# neither set widens the other. system_sdwan_operator_policies_spec pins
# both audiences against the reconciled rows.
puts "  ℹ️  SDWAN Manager policies: written by System::Governance::PolicyReconciler " \
     "(#{System::Governance::PolicyDeclarations::SDWAN_MANAGER_POLICIES.size} declared; " \
     "boot-time governance-reconcile or `rails system:governance:reconcile`)"

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
