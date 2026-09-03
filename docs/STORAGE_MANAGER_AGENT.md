# Storage Manager Agent — Operator Guide

> Status: **declared, not yet seeded** (HIER-P2DECL, Phase 2 wave 1 — 2026-09-03). The
> policy set, identity, sensor ownership and hierarchy seat are declared; the agent
> itself (seed file, prompt, approval chain, trust score, skill bindings) lands in
> wave 2. This page carries the table wave 2 fills in.

The **Storage Manager** is one of the twelve official system-extension agents. It owns the **storage data plane's autonomy surface**: storage-assignment reconciliation, volume restore and snapshot deletion. Split out of Fleet Autonomy on 2026-09-03 (HIER-P2DECL, Phase 2 wave 1).

Source of truth: `System::Governance::PolicyDeclarations::STORAGE_MANAGER_POLICIES` (identity
`"storage-manager"` in `PolicyDeclarations::AGENT_IDENTITIES`, name `"Storage Manager"`, type
`monitor`). There is no seed file yet: `PolicyReconciler` writes this set onto
the agent on the first boot after wave 2 seeds it, and **re-homes** every row
below that an established install already holds on Fleet Autonomy — in place,
verb / `is_active` / conditions / priority preserved, a
`system.intervention_policy.rehomed` audit row written — from the
`PolicyReconciler::FORMER_OWNERS` map.

---

## Charter

Twin of the `volume-snapshot-operator` set, which keeps its global-shape row for `system.volume_snapshot_delete`.

**Until wave 2 seeds the agent:** every `DecisionEngine::SIGNAL_BINDINGS` entry
that declares `owner: "storage-manager"` gates under **Fleet Autonomy** with a
`fleet.owner_agent_missing` event (`FleetAutonomyService#for_owner`), where an
established install still holds the rows. `PolicyReconciler` reports the set as
`storage-manager(agent absent)` in its drift report, and
`System::Governance::HierarchyReconciler` reports the missing Concierge child the
same way — drift, not an error.

---

## Intervention Policies

The agent ships with **3 intervention policies**:

| Action | Policy | Reached through | Why |
|---|---|---|---|
| `system.storage_assignment_reconcile` | `notify_and_proceed` | sensor: `storage_assignment_drift_sensor` → `DecisionEngine#reconcile_storage_assignment` | Re-runs the reconciliation the assignment's own after_commit would; reversible, low blast radius, operator sees the safety net firing |
| `system.restore_volume` | `require_approval` | executor: `RestoreVolumeExecutor` | Overwrites a volume from a snapshot |
| `system.volume_snapshot_delete` | `require_approval` | `SystemFleetTool#system_delete_volume_snapshot` — twin | Destroys a restore point; the snapshot schedule sensor (improvement 01a065df) must ask this category when it lands |

"Reached through" is the door whose gate resolves the row: a **sensor** lane is
gated on the Fleet Autonomy tick under this agent (HIER-P2A owner gating); an
**executor** resolves it in `BaseSkillExecutor#execute` when run as this agent
(executor re-binding is wave 2 — until then the ingress/supply-chain/DR
executors still `binds_to` Fleet Autonomy and resolve the unmatched
`require_approval` default for a moved category); a **twin** row is read only
when the MCP / REST verb is called AS this agent, and the operator row in the
paired operator set is what an operator's own call resolves.

### Tuning a policy

```ruby
# rails console (once the agent is seeded)
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

## Approval Chain

Wave 2 seeds the `Storage Manager Actions` chain (`trigger_type: autonomy_action`).
`FleetAutonomyService#for_owner` resolves the chain by the owner agent's name, so
until it exists a pending request for one of these categories lands on the
fallback agent's chain (`Fleet Autonomy Actions`).

---

## Related Documents

- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) §Intervention Policy Reference — the per-agent census this table is pinned against (`spec/docs/reference_counts_spec.rb`)
- [`CLAUDE.md`](../CLAUDE.md) — index of all extension agents, including this one
- `docs/reference/system-agent-hierarchy-proposal-2026-09-03.md` (core tree) — the Phase 2 rulings this agent comes from

_Last verified: 2026-09-03_
