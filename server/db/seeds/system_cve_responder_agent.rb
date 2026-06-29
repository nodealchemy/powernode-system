# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the CVE Responder AI agent — dedicated to CVE intake (SBOM ingestion,
# exposure scanning) and remediation orchestration. Carved out of Fleet
# Autonomy (2026-05-10) so security incidents have their own queue + can
# be elevated to higher-trust auto-remediation later without reshuffling
# fleet ops policies.

puts "\n  Seeding CVE Responder agent + policies..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

cve_prompt = <<~PROMPT
  You are the **CVE Responder** — the security-focused fleet reconciler for the
  Powernode system extension. You own the full vulnerability-response chain:
  SBOM ingest → exposure scan → triage → remediation orchestration.

  ## Charter

  Every 60s (and on `system.cve_critical_published` / `system.module_critical_upgrade_ready`
  signals) you assess the fleet's exposure: which running modules carry packages
  named by an open `System::Cve`, how severe, and whether a patched upstream
  version already exists. You produce remediation **plans** — the actual rollout
  is gated by intervention policy and (usually) operator approval.

  ## Operating Principles

  1. **Triage by real exposure, not raw CVE feed.** A CVE matters only when a
     live module's SBOM intersects its affected packages. Rank by severity ×
     blast radius (how many instances run the affected module).
  2. **Prefer the patch that already exists.** When drift AND an open exposure
     intersect on a module, the fix is to materialize the patched version and
     roll it out — surface that path first (`module_critical_upgrade_ready`).
  3. **Auto-remediation is opt-in.** `system.cve_auto_remediate` is blocked by
     default; never assume an operator wants unattended patching. Plan, notify,
     and let policy decide.
  4. **Security responses span business days.** Don't force urgency the operator
     hasn't granted; a require_approval CVE action waits in the queue (8h timeout)
     rather than auto-proceeding.
  5. **Be specific and auditable.** Name the CVE id, severity, affected packages,
     the candidate fixed version, and the rollout strategy in every plan.
PROMPT

cve_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "CVE Responder",
  agent_type: "monitor",
  source_key: "cve-responder"
)
cve_agent.assign_attributes(
  description: "CVE intake + remediation — SBOM ingest, exposure scan, patch orchestration",
  status: "active",
  autonomy_config: { "interval_seconds" => 60, "extension" => "system", "scope" => "cve" }
)
# Persona prompt + reasoning-tier model. Set system_prompt first (it writes into
# mcp_metadata in place), then reassign mcp_metadata to a fresh merged hash so
# both survive AR dirty-tracking. Security triage warrants reasoning-tier;
# resolution is left to AgentModelSelector (no hardcoded model id).
cve_agent.system_prompt = cve_prompt
cve_agent.mcp_metadata = (cve_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "reasoning" } }
)
if cve_agent.new_record?
  cve_agent.creator  = creator
  cve_agent.provider = provider
end
cve_agent.save!
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: cve_agent,
  tier: "trusted", overall: 0.80,
  dimensions: {
    reliability: 0.75, cost_efficiency: 0.75, safety: 0.92, quality: 0.80, speed: 0.65
  }
)
puts "  ✅ CVE Responder agent: #{cve_agent.previously_new_record? ? 'created' : 'updated'}"

cve_policies = {
  "system.cve_remediate"               => "require_approval",   # patch strategy needs operator review
  "system.cve_sbom_ingest"             => "auto_approve",       # importing inventory is read-shape
  "system.cve_exposure_scan"           => "auto_approve",       # scanning produces findings, no mutations
  "system.cve_auto_remediate"          => "block",              # off by default; operators opt in per-policy
  # Fires only when CriticalUpgradeAvailableSensor sees the intersection
  # of (a) drift on a package-derived module AND (b) an open CveExposure
  # on that module. The patched upstream version *already exists* — the
  # only thing left to do is materialize it locally and roll it out. This
  # is the "proactively upgrade critical modules" path: notify operators
  # and dispatch the orchestrator inline. Use the system.cve_auto_remediate
  # kill-switch to force this back to block/require_approval per-account.
  "system.module_critical_upgrade_ready" => "notify_and_proceed"
}

count = System::Seeds::AgentSetupHelpers.upsert_policies!(
  account: admin_account, agent: cve_agent,
  definitions: cve_policies
)
System::Seeds::AgentSetupHelpers.clean_stale_policies!(
  account: admin_account, agent: cve_agent,
  keep_keys: cve_policies.keys
)
puts "  ✅ CVE Responder policies: #{count} changed (#{cve_policies.size} total)"

cve_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "CVE Responder Actions"
)
cve_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 8,  # CVE response often spans business days
  steps: [ {
    "name" => "Security Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if cve_chain.new_record? || cve_chain.changed?
  cve_chain.save!
  puts "  ✅ CVE Responder Approval Chain: created/updated"
else
  puts "  ✅ CVE Responder Approval Chain: already up to date"
end
