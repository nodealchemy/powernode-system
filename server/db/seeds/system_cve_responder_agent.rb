# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the CVE Responder AI agent — dedicated to CVE intake (SBOM ingestion,
# exposure scanning) and remediation orchestration. Carved out of Fleet
# Autonomy (2026-05-10) so security incidents have their own queue + can
# be elevated to higher-trust auto-remediation later without reshuffling
# fleet ops policies.

puts "\n  Seeding CVE Responder agent + policies..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: ["anthropic", "openai"]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

cve_agent = admin_account.ai_agents.find_or_initialize_by(
  name: "CVE Responder",
  agent_type: "monitor"
)
cve_agent.assign_attributes(
  description: "CVE intake + remediation — SBOM ingest, exposure scan, patch orchestration",
  status: "active",
  autonomy_config: { "interval_seconds" => 60, "extension" => "system", "scope" => "cve" }
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
  steps: [{
    "name" => "Security Operator Approval",
    "approvers" => [{ "type" => "permission", "value" => "system.infra_tasks.control" }],
    "required_approvals" => 1
  }]
)
if cve_chain.new_record? || cve_chain.changed?
  cve_chain.save!
  puts "  ✅ CVE Responder Approval Chain: created/updated"
else
  puts "  ✅ CVE Responder Approval Chain: already up to date"
end
