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
  preferred_provider_types: ["anthropic", "openai"]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

# ── Fleet Autonomy agent ─────────────────────────────────────────────────
#
# Ai::Agent requires a creator (User) + provider (Ai::Provider) at create
# time. Pick the admin user + first available provider as defaults; an
# operator can swap the provider later in the agents UI.

fleet_agent = admin_account.ai_agents.find_or_initialize_by(
  name: "Fleet Autonomy",
  agent_type: "monitor"
)
fleet_agent.assign_attributes(
  description: "Self-improving fleet reconciler — runs sensors, gates actions, extracts learnings",
  status: "active",
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

fleet_policies = {
  # Routine + reversible (auto)
  "system.cert_rotate"             => "auto_approve",

  # Read/notify
  "system.module_assign"           => "notify_and_proceed",
  "system.instance_reboot"         => "notify_and_proceed",

  # Sensitive — require_approval
  "system.instance_reprovision"    => "require_approval",
  "system.instance_terminate"      => "require_approval",
  "system.cert_revoke"             => "require_approval",
  "system.module_promote_to_live"  => "require_approval",
  "system.fleet_rolling_upgrade"   => "require_approval",
  "system.region_expansion"        => "require_approval",
  "system.capacity_resize"         => "require_approval",

  # Stale BGP observations are pure observation — no remediation; the
  # `observation` action_category collects them for dashboards without
  # entering the approval pipeline.
  "system.observation"             => "auto_approve",

  # Package repository ingestion. Sync is routine + reversible (just
  # refreshes cached metadata); module creation is supply-chain critical
  # (operator audits each new package entering the fleet); refresh requires
  # approval for non-CVE drifts (intervention policy splits CVE-flagged
  # refresh out into auto-approve via the executor's payload metadata).
  "system.package_repository.sync" => "auto_approve",
  "system.package_module.create"   => "require_approval",
  "system.package_module.refresh"  => "require_approval",

  # Architecture catalog. Propose auto-approves at the policy layer
  # because the Ai::AgentProposal it creates is itself the human-review
  # gate. Direct CRUD requires approval — even with system.architectures.manage,
  # mutating the catalog surfaces for operator confirmation because it
  # affects every account's available platforms.
  "system.architecture.propose" => "auto_approve",
  "system.architecture.create"  => "require_approval",
  "system.architecture.update"  => "require_approval",
  "system.architecture.delete"  => "require_approval"

  # NOTE: SDWAN policies moved to system_sdwan_manager_agent.rb (2026-05-10).
  # NOTE: CVE policies moved to system_cve_responder_agent.rb (2026-05-10).
  # NOTE: Disk Image policies moved to system_disk_image_manager_agent.rb (2026-05-10).
  # The 5-agent split keeps per-domain approval queues independent and lets
  # operators pause one domain (e.g. SDWAN during a maintenance window)
  # without halting fleet ops.
}

count = System::Seeds::AgentSetupHelpers.upsert_policies!(
  account: admin_account, agent: fleet_agent,
  definitions: fleet_policies
)
System::Seeds::AgentSetupHelpers.clean_stale_policies!(
  account: admin_account, agent: fleet_agent,
  keep_keys: fleet_policies.keys
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
  steps: [{
    "name" => "Fleet Operator Approval",
    "approvers" => ["*"],
    "required_approvals" => 1
  }]
)
if fleet_chain.new_record? || fleet_chain.changed?
  fleet_chain.save!
  puts "  ✅ Fleet Approval Chain: created/updated"
else
  puts "  ✅ Fleet Approval Chain: already up to date"
end
