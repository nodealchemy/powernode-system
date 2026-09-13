# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the Fleet Autonomy AI agent and the fleet approval chain.
#
# Reference: Golden Eclipse plan M7 — fleet_autonomy_agent seed.
# Mirrors trading_overseer_autonomy.rb shape so trading + fleet decisions
# share the same approval queue UI without code paths diverging.

puts "\n  Seeding Fleet Autonomy agent..."

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
# tool_access.tool_families is its duty surface (IMP-777f59d4cc1e): sensors and
# their config, signals and failure attribution, drift and boot-image rollout,
# instance module refresh, and recording what a tick learned. Reassigned (not
# mutated in place) so it persists beside the in-place system_prompt.
fleet_agent.mcp_metadata = (fleet_agent.mcp_metadata || {}).merge(
  "tool_access" => { "tool_families" => %w[
    system_drift_report system_recent_signals system_attribute_failure system_inspect_correlation
    system_get_sensor_config system_update_sensor_config system_get_silent_instances system_list_instances
    system_get_instance system_refresh_instance_modules system_upgrade_boot_image system_list_nodes system_get_node
    system_list_modules system_list_module_versions system_module_diff system_list_tasks system_get_task
    system_discover_packages create_learning
  ] }
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

# ── Intervention policies: NOT written here ──────────────────────────────
# System::Governance::PolicyReconciler is the SINGLE WRITER of the declared
# set (PolicyDeclarations::FLEET_AUTONOMY_POLICIES, POLICY_SETS "fleet-autonomy") —
# on every boot, the first one included (rails-start.sh runs the governance
# reconcile after db:seed), and via `rails system:governance:reconcile`. It
# writes against the account's acting principal for this agent (HIER-P2I)
# and creates absence only, so an operator's tuned verb survives a re-seed.
# The approval chain below stays here: the reconciler writes policy rows and
# nothing else. Proposal §5 ruling 7 / IMP-10e4f6c3bcd2.
# An established install's rows for the categories HIER-P2A / HIER-P2DECL
# moved off this agent are RE-HOMED by the reconciler
# (PolicyReconciler::FORMER_OWNERS), tuning preserved — nothing here deletes.
puts "  ℹ️  Fleet Autonomy policies: written by System::Governance::PolicyReconciler " \
     "(#{System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES.size} declared; " \
     "boot-time governance-reconcile or `rails system:governance:reconcile`)"

# ── Fleet Approval Chain ────────────────────────────────────────────────
# Single-step chain for fleet require_approval actions. The trading approval
# queue UI surfaces fleet requests via source_type="system_fleet" without UI
# changes.

System::Seeds::AgentSetupHelpers.ensure_approval_chain!(
  account: admin_account,
  name: "Fleet Autonomy Actions",
  label: "Fleet",
  timeout_hours: 4,
  steps: [ {
      "name" => "Fleet Operator Approval",
      "approvers" => [ "*" ],
      "required_approvals" => 1
    } ]
)
