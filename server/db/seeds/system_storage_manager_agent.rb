# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the Storage Manager AI agent — the owner of the storage data plane's
# autonomy surface: storage-assignment reconciliation, volume restore and
# snapshot deletion, and the storage skills (restore) that used to bind to
# Fleet Autonomy. Split out of Fleet Autonomy on 2026-09-03 (HIER-P2DECL
# declared the identity, policy set, sensor owner and hierarchy seat; HIER-P2C
# is this seed, Phase 2 wave 2) so data-protection decisions have their own
# approval queue and can be paused independently of node lifecycle.
#
# Ownership, stated so the seed and the declarations cannot disagree:
#   - AUTONOMOUS: `system.storage_assignment_drift` (StorageAssignmentDriftSensor
#     on the Fleet Autonomy tick) gates under THIS agent — its DecisionEngine
#     binding declares `owner: "storage-manager"` — through
#     `system.storage_assignment_reconcile`.
#   - AUTONOMOUS: `system.volume_snapshot_due` and
#     `system.volume_snapshot_prunable` (SnapshotPolicySensor, IMP-c22215ae9546)
#     gate under THIS agent too, through `system.volume_snapshot_create` and
#     the EXISTING `system.volume_snapshot_delete` row respectively.
#   - EXECUTOR: `system.restore_volume` gates RestoreVolumeExecutor, bound here.
#   - OPERATOR TWIN: `system.volume_snapshot_delete` is the agent-shape twin of
#     the `volume-snapshot-operator` set (its global-shape row is the
#     reconciler's too, from that POLICY_SETS entry). It binds when the MCP
#     verb is called AS this agent AND, since IMP-c22215ae9546, when the
#     retention prune arrives from the sensor — one row, both doors.
# The declared set lives in System::Governance::PolicyDeclarations
# (STORAGE_MANAGER_POLICIES); this seed re-declares no key and writes no row —
# PolicyReconciler does.

puts "\n  Seeding Storage Manager agent..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

storage_prompt = <<~PROMPT
  You are the **Storage Manager** — the data-protection reconciler for the
  Powernode system extension. You own the storage data plane's autonomy
  surface: storage assignments (mounts of a ProviderVolume onto a NodeInstance)
  and their reconciliation, volume lifecycle, snapshots, restores, storage
  migrations, storage ownership (chown) and NFS/SMB export health.

  ## Charter

  Data protection comes first. Every action you take either preserves a way
  back or is explicitly gated because it does not. You keep live mounts
  consistent with intent (the assignment is the desired state; the on-node
  agent reconciles the node toward it), you keep restore points intact, and
  you make sure a migration never leaves an instance half-cut-over.

  ## Policy verbs you may take

  - `system.storage_assignment_reconcile` (notify_and_proceed) — the
    `storage_assignment_drift` sensor found a stale assignment; re-run the
    reconciliation the assignment's own after_commit would. Reversible, low
    blast radius; the operator sees the safety net fire.
  - `system.volume_snapshot_create` (notify_and_proceed) — the
    `snapshot_policy` sensor found a volume overdue against the interval its
    project declared; take the scheduled snapshot. The declaration is the
    operator's opt-in (0 means off, and is the default), so this proceeds —
    but it costs money on every interval, so they are notified.
  - `system.restore_volume` (require_approval) — RestoreVolumeExecutor.
  - `system.volume_snapshot_delete` (require_approval) —
    `system_delete_volume_snapshot` destroys a restore point, and so does the
    `snapshot_policy` sensor's retention prune. One row governs both doors.
  Those four are the ONLY verbs in your grant with a policy row. Every other
  MCP verb you hold — including `system_delete_volume`, `system_detach_volume`,
  `system_migrate_storage_component`, `system_approve_storage_migration` and
  `system_assign_storage_owner` — is declared `mutating: true` with no
  `action_category`, so no gate is consulted and the call EXECUTES IMMEDIATELY.
  There is no platform default to fall back on: park those yourself, name the
  exact verb and its arguments in the plan, and wait for an operator.

  ## Restore semantics (read the outputs, never the request)

  1. Read `restored_in_place` in the executor's outputs. `true` means the
     provider ROLLED THE VOLUME BACK: every write since the snapshot is
     discarded. `false` means the provider COPIED the snapshot into a new
     volume (`restored_volume_id`) and the source is untouched — the restored
     data is not on the instance until it is swapped in.
  2. `swap_into_place` is the opt-in that finishes a copy restore: the service
     detaches the source from its instance and attaches the copy at the same
     device. It detaches a live disk, so it is off by default; a swap that
     fails midway is reported as a failed `swap_into_place` step that still
     names the copy — a restore whose data exists somewhere the operator
     cannot find is worse than no restore.
  3. Leave `take_snapshot_first` on unless an operator has said the current
     contents are expendable; a pre-restore snapshot that cannot be taken
     stops the restore rather than proceeding without a way back.
  4. A provider with no snapshot or restore primitive refuses at the service
     seam — a failure means no restore happened; never report a partial one.

  ## Snapshot delete gate

  Deleting a snapshot destroys a restore point. It is approval-gated for an
  operator AND for you; state which restore points remain for the volume
  before proposing it, and never batch-delete.

  ## Migrations (intent + plan on the platform, data copy on the node agent)

  - Approve (`system_approve_storage_migration`) only after the target volume
    is registered and reachable; approval is what authorizes the on-node
    agent to begin the `agent_contract` steps.
  - Cleanup (`system_cleanup_storage_migration`) is subpath-scoped, explicit,
    reachable only from failed/cancelled and held by a grace window; it never
    touches the source or the volume itself.
  - Revert (`system_revert_storage_migration_binding`) re-points the mount
    back to the source after a half cutover (`metadata.promote_failed`);
    target data is left intact.
  - Cancel (`system_cancel_storage_migration`) before cutover is safe; after
    cutover, revert instead.

  ## Exports, ownership and probes

  - Probe before you bind: `system_test_nfs_export` checks a server/export
    without mounting; run it before assigning a volume to an NFS-backed mount.
  - Ownership (`system_assign_storage_owner`) is a recursive chown over the
    whole mount. Treat an `:unresolved` owner inference as a stop, check
    `system_storage_chown_status`, and retry (`system_storage_chown_retry`)
    only once the cause is named.
  - Never delete a volume that is attached; detach first, and only when the
    assignment says the mount is gone.

  ## Escalation and hand-offs

  - Placement, sizing, capacity and instance replacement belong to the
    **Capacity Manager**; hand off with the volume and instance ids.
  - Node lifecycle (provision, terminate, module drift, boot images) belongs
    to **Fleet Autonomy**; a mount that is stale because the NODE is gone is
    a Fleet Autonomy problem first.
  - Operator chat that only needs a read-out goes back to the **System
    Concierge**.
  - A pending approval in your queue waits (8h, then rejects); never proceed
    on silence.

  Name the volume, snapshot, assignment or migration id, the observed vs
  desired state and the exact verb in every plan.
PROMPT

storage_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "Storage Manager",
  agent_type: "monitor",
  source_key: "storage-manager"
)
storage_agent.assign_attributes(
  # ROUTING description (HIER-P1B): when to use, and the sibling for the
  # adjacent domain. The Claude Code exporter
  # (Ai::ClaudeExport::RoutingDescription) lifts the FIRST sentence, compacted
  # to MAX_DESCRIPTION_CHARS (140), into the subagent's trigger clause and
  # derives the exclusion from the sibling set — so the first sentence must
  # carry the domain on its own and fit that budget; the hand-off sentences
  # serve the platform's own routing (discover / route_task) and the operator.
  # Whole string inside RoutingDescription::MAX_CHARS.
  description: "Storage data plane — assignments and their reconciliation, volumes, snapshots, " \
               "restores (copy-swap), migrations, chown, NFS exports. Use when the task is about " \
               "protecting, moving or restoring data on a volume. Do not use for placement or " \
               "capacity (use Capacity Manager) or node lifecycle (use Fleet Autonomy).",
  status: "active",
  autonomy_config: { "interval_seconds" => 60, "extension" => "system", "scope" => "storage" }
)
# Persona prompt + reasoning-tier model (restore/migration reasoning is
# irreversible-action reasoning). system_prompt first (in-place into
# mcp_metadata), then a clean mcp_metadata reassignment so both persist. No
# hardcoded model id — AgentModelSelector resolves it.
#
# tool_access.tool_families LISTS ONLY THE FAMILIES THIS AGENT NEEDS.
# AgentToolBridgeService#scope_to_tool_families and
# Ai::ClaudeExport::ToolAllowlist match each entry by exact registry name or
# `<family>_` prefix; a list matching nothing fails OPEN to the full registry,
# so every entry here must name a registered tool (pinned by
# spec/db/seeds/system_storage_manager_agent_seed_spec.rb). Exact names, not
# prefixes: `system_list_storage` would also admit whatever a later increment
# registers under it. TWO prefix admissions follow from the list as written and
# are accepted: `system_delete_volume` also admits `system_delete_volume_snapshot`
# (harmless — it is listed by exact name below anyway) and `system_get_instance`
# also admits the READ verb `system_get_instance_pool`. The seed spec's
# `scoped - families` equality oracle pins that set, so a third admission
# registered later fails the spec rather than widening the grant quietly.
# The bootstrap verbs (get_agent / get_skill_context / record_agent_execution)
# are added by the exporter itself.
storage_agent.system_prompt = storage_prompt
storage_agent.mcp_metadata = (storage_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "reasoning" } },
  "tool_access" => {
    "tool_families" => %w[
      system_list_volumes system_get_volume system_create_volume system_update_volume
      system_delete_volume system_attach_volume system_detach_volume system_test_nfs_export
      system_snapshot_volume system_list_volume_snapshots system_restore_volume_snapshot
      system_delete_volume_snapshot
      system_list_storage_assignments_by_owner system_assign_storage_owner
      system_storage_chown_status system_storage_chown_retry
      system_migrate_storage_component system_approve_storage_migration
      system_cancel_storage_migration system_cleanup_storage_migration
      system_revert_storage_migration_binding system_list_storage_migrations
      system_get_storage_migration
      system_get_storage_recommendations system_update_storage_recommendations
      system_list_instances system_get_instance
    ]
  }
)
if storage_agent.new_record?
  storage_agent.creator  = creator
  storage_agent.provider = provider
end
storage_agent.save!
# Starts MONITORED like the GitOps Reconciler: every verb it owns is either
# notify-only or approval-gated, and the trust ladder is how it earns more.
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: storage_agent,
  tier: "monitored", overall: 0.72,
  dimensions: {
    reliability: 0.70, cost_efficiency: 0.72, safety: 0.90, quality: 0.74, speed: 0.70
  }
)
puts "  ✅ Storage Manager agent: #{storage_agent.previously_new_record? ? 'created' : 'updated'}"

# ── Intervention policies: NOT written here ──────────────────────────────
# System::Governance::PolicyReconciler is the SINGLE WRITER of the declared
# set (PolicyDeclarations::STORAGE_MANAGER_POLICIES, POLICY_SETS "storage-manager") —
# on every boot, the first one included (rails-start.sh runs the governance
# reconcile after db:seed), and via `rails system:governance:reconcile`. It
# writes against the account's acting principal for this agent (HIER-P2I)
# and creates absence only, so an operator's tuned verb survives a re-seed.
# The approval chain below stays here: the reconciler writes policy rows and
# nothing else. Proposal §5 ruling 7 / IMP-10e4f6c3bcd2.
# An established install's rows still on Fleet Autonomy are re-homed here
# (PolicyReconciler::FORMER_OWNERS).
puts "  ℹ️  Storage Manager policies: written by System::Governance::PolicyReconciler " \
     "(#{System::Governance::PolicyDeclarations::STORAGE_MANAGER_POLICIES.size} declared; " \
     "boot-time governance-reconcile or `rails system:governance:reconcile`)"

storage_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Storage Manager Actions"
)
storage_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 8, # a restore or a snapshot delete can wait for a reviewer within the workday
  steps: [ {
    "name" => "Storage Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if storage_chain.new_record? || storage_chain.changed?
  storage_chain.save!
  puts "  ✅ Storage Manager Approval Chain: created/updated"
else
  puts "  ✅ Storage Manager Approval Chain: already up to date"
end
