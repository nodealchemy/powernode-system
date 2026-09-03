# Storage Manager Agent — Operator Guide

> Status: **seeded** (HIER-P2C, Phase 2 wave 2 — 2026-09-03). HIER-P2DECL (wave 1)
> declared the identity, the policy set, the sensor ownership and the hierarchy seat;
> this increment shipped the agent itself: seed file, prompt, approval chain, trust
> score, tool families, skill binding and the Claude Code counterpart.

The **Storage Manager** is one of the twelve official system-extension agents. It owns the **storage data plane's autonomy surface**: storage-assignment reconciliation, volume restore and snapshot deletion — and, through its bound skill and tool families, the volume lifecycle, migrations, ownership (chown) and NFS export probes around them. Split out of Fleet Autonomy on 2026-09-03 (HIER-P2DECL, Phase 2 wave 1; seeded by HIER-P2C, wave 2).

Source of truth: `db/seeds/system_storage_manager_agent.rb`, which consumes
`System::Governance::PolicyDeclarations::STORAGE_MANAGER_POLICIES` (identity
`"storage-manager"` in `PolicyDeclarations::AGENT_IDENTITIES`, name `"Storage Manager"`, type
`monitor`) and never re-declares a key. The seed writes the agent-shape rows on a
first boot; on every boot after that `PolicyReconciler` asserts the set and
**re-homes** every row below that an established install still holds on Fleet
Autonomy — in place, verb / `is_active` / conditions / priority preserved, a
`system.intervention_policy.rehomed` audit row written — from the
`PolicyReconciler::FORMER_OWNERS` map.

---

## Charter

Data protection first. Every action either preserves a way back or is gated because it does not. The agent keeps live mounts consistent with intent (the `StorageAssignment` is the desired state; the on-node agent reconciles the node toward it), keeps restore points intact, and makes sure a migration never leaves an instance half-cut-over. The seeded prompt spells out the restore semantics it reasons over (`restored_in_place`, `swap_into_place`, `take_snapshot_first` — IMP-e025722ef14e), the snapshot delete gate, the migration approve / cleanup / revert rules, the NFS probe-before-bind rule and the chown stop conditions.

Twin of the `volume-snapshot-operator` set, which keeps its global-shape row for `system.volume_snapshot_delete`.

**Hand-offs.** Placement, sizing, capacity and instance replacement go to the **Capacity Manager**; node lifecycle (provision, terminate, module drift, boot images) goes to **Fleet Autonomy**; a read-only operator question goes back to the **System Concierge**. The routing description the seed carries says the same thing, because HIER-P1B exports it verbatim as the Claude Code subagent description.

**Identity.** GLOBAL canonical (`account_id` nil, `is_system`, `source_key: "storage-manager"`, slug `storage-manager`), created through `AgentSetupHelpers.find_or_initialize_global_agent` — a stray account-scoped agent of the same name raises `CanonicalAgentConflict`; the seed never adopts it. Reasoning-tier model via `mcp_metadata.model_config.model_requirements` (no pinned provider or model id). Trust score starts **monitored** (0.72) like the GitOps Reconciler. Attached under the System Concierge by `db/seeds/system_agent_hierarchy.rb` with a conservative, depth-2 leaf delegation policy.

**Tool families.** `tool_access.tool_families` is scoped to the storage MCP verbs (`system_*_volume*`, `system_*_volume_snapshot*`, `system_*_storage_migration*`, `system_list_storage_assignments_by_owner`, `system_assign_storage_owner`, `system_storage_chown_*`, `system_*_storage_recommendations`, `system_test_nfs_export`) plus the two instance reads (`system_list_instances`, `system_get_instance`). `AgentToolBridgeService` scopes the platform registry to that list at runtime and `Ai::ClaudeExport::ToolAllowlist` derives the Claude Code `tools:` allowlist from it; every entry is an exact registered name (pinned by the seed spec), because a list that matches nothing fails open to the whole registry. The matcher also admits `<family>_`-prefixed names, which produces exactly two admissions over this list: `system_delete_volume` admits `system_delete_volume_snapshot` (harmless — that verb is listed by exact name too) and `system_get_instance` admits the read verb `system_get_instance_pool`. Both are accepted; the seed spec pins the admitted set with a `scoped - families` equality oracle, so a third one registered later fails rather than widening the grant quietly.

---

## Intervention Policies

The agent ships with **3 intervention policies**:

| Action | Policy | Reached through | Why |
|---|---|---|---|
| `system.storage_assignment_reconcile` | `notify_and_proceed` | sensor: `storage_assignment_drift_sensor` → `DecisionEngine#reconcile_storage_assignment` | Re-runs the reconciliation the assignment's own after_commit would; reversible, low blast radius, operator sees the safety net firing |
| `system.restore_volume` | `require_approval` | executor: `RestoreVolumeExecutor` (bound to this agent) | Overwrites a volume from a snapshot on an in-place provider; copies it into a new volume otherwise |
| `system.volume_snapshot_delete` | `require_approval` | `SystemFleetTool#system_delete_volume_snapshot` — twin | Destroys a restore point; the snapshot schedule sensor (improvement 01a065df) must ask this category when it lands |

"Reached through" is the door whose gate resolves the row: a **sensor** lane is
gated on the Fleet Autonomy tick under this agent (HIER-P2A owner gating —
`FleetAutonomyService#for_owner("storage-manager")` resolves to this agent, so
the `fleet.owner_agent_missing` fallback no longer fires for it); an
**executor** resolves it in `BaseSkillExecutor#execute` when run as this agent
(`RestoreVolumeExecutor` binds here since HIER-P2C, so its gate reads this
agent's row rather than the unmatched `require_approval` default); a **twin**
row is read only when the MCP / REST verb is called AS this agent, and the
operator row in the paired operator set is what an operator's own call resolves.

### Tuning a policy

```ruby
# rails console
agent = Ai::Agent.find_by(name: "Storage Manager")
Ai::InterventionPolicy.find_by(
  ai_agent_id: agent.id, action_category: "system.storage_assignment_reconcile"
).update!(policy: "require_approval")
```

`PolicyReconciler` is absence-only: a tuned verb is never reset by a boot.

---

## Sensor → Action Map

| Sensor | Signal | Triggers action | Policy default |
|---|---|---|---|
| `storage_assignment_drift_sensor` | `system.storage_assignment_drift` | `system.storage_assignment_reconcile` | `notify_and_proceed` |

See [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) for sensor implementation details.

---

## Skills

| Skill | Executor | Gate |
|---|---|---|
| `system-restore-volume` | `RestoreVolumeExecutor` | `system.restore_volume` (`require_approval`, `blast_radius: :high`, no rollback — the pre-restore snapshot is the only way back) |

`system-attach-storage` (`AttachStorageExecutor`) stays bound to Fleet Autonomy: it is a provisioning-adaptation step (`Ai::Provisioning::AdaptationProposerService`, the provisioning mission template's `execute` phase), seeded by `system_provisioning_skills_seed.rb` under the `provisioning` subdomain, not a storage data-protection verb.

---

## Approval Chain

`Storage Manager Actions` (`trigger_type: autonomy_action`, sequential, one approver holding `system.infra_tasks.control`, **8-hour timeout, reject on timeout** — a restore or a snapshot delete can wait for a reviewer within the workday; it never proceeds on silence). `FleetAutonomyService#for_owner` resolves the chain by the owner agent's name, so a pending request for one of these categories lands here rather than on `Fleet Autonomy Actions`.

---

## Claude Code counterpart

`.claude/agents/powernode/storage-manager.md` (core tree) is regenerated by `rails claude:sync_agents` from this agent: the routing description, the `tools:` allowlist derived from the tool families above, the delegation section and the baseline guardrails. Edit the seed, never the file.

---

## Related Documents

- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) §Intervention Policy Reference — the per-agent census this table is pinned against (`spec/docs/reference_counts_spec.rb`)
- [`STORAGE_SUBSYSTEM.md`](./STORAGE_SUBSYSTEM.md) — the storage data plane this agent reconciles (models, services, MCP surface, dangerous operations)
- [`SKILL_EXECUTORS.md`](./SKILL_EXECUTORS.md) — agent → skill bindings
- [`CLAUDE.md`](../CLAUDE.md) — index of all extension agents, including this one
- `docs/reference/system-agent-hierarchy-proposal-2026-09-03.md` (core tree) — the Phase 2 rulings this agent comes from
- Seed spec: `server/spec/db/seeds/system_storage_manager_agent_seed_spec.rb`

_Last verified: 2026-09-03_
