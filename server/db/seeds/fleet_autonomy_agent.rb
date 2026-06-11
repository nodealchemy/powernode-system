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
  # Node-cert rotation has NO server-side actuator: NodeEnrollmentService
  # refresh requires the on-node agent's CSR (private keys never leave the
  # node), so the platform cannot rotate autonomously. require_approval
  # keeps each expiring cert visible as an operator work item instead of a
  # proceed lane that silently does nothing (audit F3-03).
  "system.cert_rotate"             => "require_approval",

  # Platform ACME cert renewal (CertExpirySensor → platform_maintenance
  # cert_rotate). notify_and_proceed: renewal is reversible/low-blast-radius
  # but can fail on CA/DNS-01 issues, so an operator should be informed.
  "system.acme_cert_rotate"        => "notify_and_proceed",

  # Phase 3 (Federation & Multi-Site) — federation peer liveness remediation
  # (FederationPeerLivenessSensor → system.federation_peer_remediate). This
  # policy MUST live on Fleet Autonomy, not SDWAN Manager: the sensor runs in
  # FleetAutonomyService::SENSORS, whose tick! gates as the "Fleet Autonomy"
  # agent, so gate_action! resolves permitted_actions against THIS agent.
  # Re-handshake / degrade / alert is low-to-medium blast radius and the
  # dedup TTL self-throttles repeat firings → notify_and_proceed.
  "system.federation_peer_remediate" => "notify_and_proceed",

  # Phase 3 (SDWAN autonomous remediation) — the 7 system.sdwan_* actions below
  # were MOVED here from system_sdwan_manager_agent.rb. Like
  # federation_peer_remediate, they fire from FleetAutonomyService::SENSORS,
  # whose tick! gates as the "Fleet Autonomy" agent — so gate_action! resolves
  # these policies against THIS agent. Seeded on SDWAN Manager they were
  # stranded (silently 'not_permitted') in the sensor path. The operator-
  # initiated sdwan.* CRUD policies stay on SDWAN Manager (gated via
  # Ai::AutonomyGate as that agent). Autonomy levels preserved from the prior
  # SDWAN Manager seed.
  "system.sdwan_peer_remediate"        => "notify_and_proceed",
  "system.sdwan_key_rotate"            => "auto_approve",
  "system.sdwan_failover"              => "require_approval",
  "system.sdwan_user_device_revoke"    => "require_approval",
  "system.sdwan_bgp_session_remediate" => "notify_and_proceed",
  "system.sdwan_vip_failover"          => "require_approval",
  "system.sdwan_route_policy_audit"    => "auto_approve",

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

  # NOTE: Operator-initiated SDWAN CRUD policies (sdwan.*) live on
  # system_sdwan_manager_agent.rb (2026-05-10) — they gate via Ai::AutonomyGate
  # as the SDWAN Manager agent. The 7 AUTONOMOUS system.sdwan_* remediation
  # policies were moved back HERE (above), because they fire from the sensor
  # path which gates as Fleet Autonomy.
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
