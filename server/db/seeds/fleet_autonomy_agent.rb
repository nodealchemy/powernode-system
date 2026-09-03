# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the Fleet Autonomy AI agent, intervention policies (per-action
# default behavior), and the fleet approval chain.
#
# Reference: Golden Eclipse plan M7 — fleet_autonomy_agent seed.
# Mirrors trading_overseer_autonomy.rb shape so trading + fleet decisions
# share the same approval queue UI without code paths diverging.

puts "\n  Seeding Fleet Autonomy agent + policies..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

# ── Fleet Autonomy agent ─────────────────────────────────────────────────
#
# Ai::Agent requires a creator (User) + provider (Ai::Provider) at create
# time. Pick the admin user + first available provider as defaults; an
# operator can swap the provider later in the agents UI.

fleet_prompt = <<~PROMPT
  You are **Fleet Autonomy** — the general-purpose fleet reconciler for the
  Powernode system extension and the agent of record for the autonomous sensor
  tick. Every 60s you run the sensor suite, route each signal through the
  DecisionEngine to an intervention-policy gate, apply the remediations the gate
  proceeds, and extract learnings from the outcomes.

  ## Charter

  You own the non-specialist fleet domain: node + module drift remediation, cert
  rotation, rolling upgrades, package-repository/module ingestion, architecture
  catalog mutations, instance lifecycle, and the autonomous remediations whose
  sensors gate as THIS agent (federation peer liveness, the autonomous
  `system.sdwan_*` set, GitOps drift surfacing, storage-assignment reconcile).
  The specialist agents (CVE Responder, SDWAN Manager, Runtime Manager, Disk
  Image Manager, GitOps Reconciler) own their own operator queues.

  ## Operating Principles

  1. **Policy decides, not you.** Resolve the action's intervention policy before
     acting; under require_approval, produce a plan and stop — never let a
     side-effectful remediation run ahead of its gate.
  2. **Dedup and self-throttle.** The same drift re-emits every tick; rely on
     fingerprint dedup so a standing condition notifies once per TTL, not every
     60s.
  3. **Stop fighting a futile remediation.** After repeated ineffective outcomes
     for a fingerprint, escalate to an operator instead of re-running the proven-
     ineffective action.
  4. **Minimal, reversible first.** Prefer the smallest reconciling action;
     destructive ones (reprovision, terminate, promote-to-live) are gated.
  5. **Every decision is auditable.** Emit the signal, the resolved policy, the
     action, and the outcome so operators review reasoning, not just effects.
PROMPT

fleet_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "Fleet Autonomy",
  agent_type: "monitor",
  source_key: "fleet-autonomy"
)
fleet_agent.assign_attributes(
  description: "Self-improving fleet reconciler — runs sensors, gates actions, extracts learnings",
  status: "active",
  system_prompt: fleet_prompt,
  autonomy_config: { "interval_seconds" => 60, "extension" => "system" }
)
# Only set creator/provider on new records — preserves operator overrides on existing rows.
if fleet_agent.new_record?
  fleet_agent.creator  = creator
  fleet_agent.provider = provider
end
fleet_agent.save!
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: fleet_agent,
  tier: "monitored", overall: 0.74,
  dimensions: {
    reliability: 0.70, cost_efficiency: 0.70, safety: 0.85, quality: 0.70, speed: 0.70
  }
)
puts "  ✅ Fleet Autonomy agent: #{fleet_agent.previously_new_record? ? 'created' : 'updated'}"

# ── Default action policies (mirrors plan M7 vocabulary) ────────────────

# Declared set now lives in System::Governance::PolicyDeclarations so the reconciler can
# assert it against a RUNNING database without executing this seed.
fleet_policies = System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES

count = System::Seeds::AgentSetupHelpers.upsert_policies!(
  account: admin_account, agent: fleet_agent,
  definitions: fleet_policies
)
System::Seeds::AgentSetupHelpers.clean_stale_policies!(
  account: admin_account, agent: fleet_agent,
  keep_keys: fleet_policies.keys,
  # F3-10: Fleet Autonomy WAS a shared agent — sibling seeds attached
  # project.* (system_provisioning_intervention_policies.rb) and
  # system.instance_pool_* (system_instance_pool_policies.rb) rows to it.
  # HIER-P2B re-pointed both at the Capacity Manager, so on a FRESH install
  # neither writes here any more.
  #
  # The carve-out STAYS, for the established install. `db:seed` is first-boot
  # only, but this file is also run on its own ("Invoke explicitly" above), and
  # an install seeded before HIER-P2B still holds those eight rows here until
  # PolicyReconciler re-homes them (PolicyReconciler::FORMER_OWNERS) — verb,
  # is_active, conditions and priority preserved. Without the exclusion a
  # targeted re-run would DELETE them first, discarding operator tuning the
  # re-home was going to carry across. Same reasoning for `owned_prefixes`:
  # clean only the namespace this seed writes.
  owned_prefixes: [ "system." ],
  excluded_prefixes: [ "system.instance_pool_" ]
)
puts "  ✅ Fleet Autonomy policies: #{count} changed (#{fleet_policies.size} total)"

# ── Fleet Approval Chain ────────────────────────────────────────────────
# Single-step chain for fleet require_approval actions. The trading approval
# queue UI surfaces fleet requests via source_type="system_fleet" without UI
# changes.

fleet_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Fleet Autonomy Actions"
)
fleet_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 4,
  steps: [ {
    "name" => "Fleet Operator Approval",
    "approvers" => [ "*" ],
    "required_approvals" => 1
  } ]
)
if fleet_chain.new_record? || fleet_chain.changed?
  fleet_chain.save!
  puts "  ✅ Fleet Approval Chain: created/updated"
else
  puts "  ✅ Fleet Approval Chain: already up to date"
end
