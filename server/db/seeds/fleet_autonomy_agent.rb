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
  # Campaign 019f505f inc 4 — BootImageDriftSensor → BootImageDriftRolloutExecutor.
  # Seeded HERE (Fleet Autonomy), not Disk Image Manager, because the sensor fires
  # from FleetAutonomyService::SENSORS and gates as THIS agent (same reason
  # system.disk_image_publication_investigate lives here). A fleet-wide in-place
  # reboot rollout is high blast radius → require_approval; the executor plans
  # canary-first and dispatches the batch on approval.
  "system.node_boot_image_drift"   => "require_approval",
  "system.region_expansion"        => "require_approval",
  "system.capacity_resize"         => "require_approval",

  # Stale BGP observations are pure observation — no remediation; the
  # `observation` action_category collects them for dashboards without
  # entering the approval pipeline.
  "system.observation"             => "auto_approve",

  # Stale storage assignment re-reconciliation (StorageAssignmentDriftSensor,
  # audit F3-07). notify_and_proceed: it re-runs the same reconciliation the
  # assignment's own after_commit would — reversible and low blast radius —
  # but the operator should see that the safety net is firing.
  "system.storage_assignment_reconcile" => "notify_and_proceed",

  # GitOps drift surfaced by GitopsDriftSensor (in FleetAutonomyService::SENSORS,
  # so it gates as THIS agent — same reason federation_peer_remediate and the
  # autonomous sdwan_* policies live here, not on the GitOps Reconciler agent
  # that authors the proposals). notify_and_proceed: drift is informational
  # (the reconciler opens proposals for the actual apply); without this binding
  # the signal was classified :skipped and never reached the operator. Deduped
  # per repo+revision fingerprint, so a standing drift notifies once per TTL.
  "system.gitops_drift_remediate" => "notify_and_proceed",

  # DK3 of the disk-image-CI restoration — DiskImagePublicationFailureStreakSensor
  # lives in FleetAutonomyService::SENSORS (not Disk Image Manager's own tick),
  # so it gates as THIS agent — same reason federation_peer_remediate /
  # gitops_drift_remediate / sdwan_* live here rather than on their specialist
  # agent. notify_and_proceed: no auto-remediation exists (a broken CI pipeline
  # needs operator investigation), this only surfaces the streak; deduped
  # per-platform via the sensor's fingerprint.
  "system.disk_image_publication_investigate" => "notify_and_proceed",

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
  keep_keys: fleet_policies.keys,
  # F3-10: Fleet Autonomy is a shared agent — sibling seeds attach project.*
  # (system_provisioning_intervention_policies.rb) and system.instance_pool_*
  # (system_instance_pool_policies.rb) policies to it. Clean only the
  # namespace this seed owns so a targeted re-run can't destroy theirs.
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
