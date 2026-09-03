# Capacity Manager Agent — Operator Guide

> Status: **declared, not yet seeded** (HIER-P2DECL, Phase 2 wave 1 — 2026-09-03). The
> policy set, identity, sensor ownership and hierarchy seat are declared; the agent
> itself (seed file, prompt, approval chain, trust score, skill bindings) lands in
> wave 2. This page carries the table wave 2 fills in.

The **Capacity Manager** is one of the twelve official system-extension agents. It owns fleet **capacity**: disaster-recovery replacement of unrecoverable instances, cost-bearing expansion, workload relocation, warm instance pools, the `project.*` provisioning / adaptation verbs, platform-deployment scaling and the cordon. Split out of Fleet Autonomy on 2026-09-03 (HIER-P2DECL, Phase 2 wave 1) so capacity decisions have an independent queue from the node-lifecycle remediation core.

Source of truth: `System::Governance::PolicyDeclarations::CAPACITY_MANAGER_POLICIES` (identity
`"capacity-manager"` in `PolicyDeclarations::AGENT_IDENTITIES`, name `"Capacity Manager"`, type
`monitor`). There is no seed file yet: `PolicyReconciler` writes this set onto
the agent on the first boot after wave 2 seeds it, and **re-homes** every row
below that an established install already holds on Fleet Autonomy — in place,
verb / `is_active` / conditions / priority preserved, a
`system.intervention_policy.rehomed` audit row written — from the
`PolicyReconciler::FORMER_OWNERS` map.

---

## Charter

Twin of three operator-only sets, which keep their rows: `instance-pool-operator` (the four gated pool verbs at the global shape), `platform-scaling` and `instance-cordon-operator`. The agent shape carries all eight pool verbs; the operator shape only the four a gate site passes (IMP-5a2b801f3386).

**Until wave 2 seeds the agent:** every `DecisionEngine::SIGNAL_BINDINGS` entry
that declares `owner: "capacity-manager"` gates under **Fleet Autonomy** with a
`fleet.owner_agent_missing` event (`FleetAutonomyService#for_owner`), where an
established install still holds the rows. `PolicyReconciler` reports the set as
`capacity-manager(agent absent)` in its drift report, and
`System::Governance::HierarchyReconciler` reports the missing Concierge child the
same way — drift, not an error.

---

## Intervention Policies

The agent ships with **22 intervention policies**:

| Action | Policy | Reached through | Why |
|---|---|---|---|
| `system.instance_replace` | `require_approval` | sensor: `instance_unrecoverable_sensor` → `ReplaceInstanceExecutor` | Disaster recovery for an instance a reboot cannot recover; separate from Fleet Autonomy's `system.instance_reprovision` |
| `system.instance_reap` | `require_approval` | executor: `ReapInstanceExecutor` (second approval asked by the replace) | The destructive half of a replace, split out so it can be refused while the additive half proceeds |
| `system.region_expansion` | `require_approval` | executor / Concierge | Cost-bearing |
| `system.capacity_resize` | `require_approval` | executor / Concierge (`capacity_recommend` proposes) | Cost-bearing |
| `system.relocate_workload` | `require_approval` | executor / Concierge | Workload relocation |
| `system.instance_pool_create` | `require_approval` | operator door (`Ai::GatedActions`) — twin | Capacity commitment |
| `system.instance_pool_update` | `notify_and_proceed` | agent vocabulary, no gate site | Changes pool size targets |
| `system.instance_pool_ceiling_raise` | `require_approval` | operator door — twin | Raises target/max — commits spend |
| `system.instance_pool_archive` | `require_approval` | operator door — twin | PATCH twin of the gated destroy |
| `system.instance_pool_delete` | `require_approval` | operator door — twin | Removes pool + ready instances |
| `system.instance_pool_replenish` | `auto_approve` | `System::Executors::InstancePool::ReplenishPool` (deliberately ungated) | Tops up to target — routine |
| `system.instance_pool_drain` | `require_approval` | agent vocabulary, no gate site | Halts replenishment |
| `system.instance_pool_acquire` | `auto_approve` | agent vocabulary, no gate site | Claim a ready member — fast path |
| `project.adapt` | `notify_and_proceed` | sensor: `project_slo_sensor` (`project_slo_violation`, `project_drift`) + `System::AdaptationGate` | Generic SLO-driven adaptation |
| `project.cost_control` | `notify_and_proceed` | sensor: `project_slo_sensor` (`project_cost_breach`) + `AdaptationGate` | Cost-driven downscale |
| `project.scale_horizontal` | `auto_approve` | `AdaptationGate` (bounded by the `auto_apply_window` condition override) | Replica adjust within the auto-scale ceiling |
| `project.relocate` | `require_approval` | `AdaptationGate` | Cross-region move |
| `project.schema_change` | `require_approval` | `AdaptationGate` | Storage / schema mutation |
| `project.security_change` | `require_approval` | `AdaptationGate` | SDWAN / firewall change |
| `system.platform.scale_out` | `auto_approve` | `System::Platform::ReplicaReconciler` — twin | Auto-executes inside the deployment's declared window, parks otherwise |
| `system.platform.scale_in` | `require_approval` | `ReplicaReconciler` — twin | Terminates instances — not reversible |
| `system.instance_cordon` | `require_approval` | `SystemFleetTool` cordon / uncordon — twin | Takes capacity out of / back into scheduling |

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
agent = Ai::Agent.find_by(name: "Capacity Manager")
Ai::InterventionPolicy.find_by(
  ai_agent_id: agent.id, action_category: "system.instance_replace"
).update!(policy: "notify_and_proceed")
```

`PolicyReconciler` is absence-only: a tuned verb is never reset by a boot.

---

## Sensor → Action Map

| Sensor | Signal | Triggers action | Policy default |
|---|---|---|---|
| `instance_unrecoverable_sensor` | `system.instance_unrecoverable` | `system.instance_replace` | `require_approval` |
| `project_slo_sensor` | `system.project_slo_violation`, `system.project_drift` | `project.adapt` | `notify_and_proceed` |
| `project_slo_sensor` | `system.project_cost_breach` | `project.cost_control` | `notify_and_proceed` |
| (core) `Ai::Provisioning::AdaptationDispatchService` → `System::AdaptationGate` | an `adaptation_diff` plan | `project.<change_type>` | per row |

See [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) for sensor implementation details.

---

## Approval Chain

Wave 2 seeds the `Capacity Manager Actions` chain (`trigger_type: autonomy_action`).
`FleetAutonomyService#for_owner` resolves the chain by the owner agent's name, so
until it exists a pending request for one of these categories lands on the
fallback agent's chain (`Fleet Autonomy Actions`).

---

## Related Documents

- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) §Intervention Policy Reference — the per-agent census this table is pinned against (`spec/docs/reference_counts_spec.rb`)
- [`CLAUDE.md`](../CLAUDE.md) — index of all extension agents, including this one
- `docs/reference/system-agent-hierarchy-proposal-2026-09-03.md` (core tree) — the Phase 2 rulings this agent comes from

_Last verified: 2026-09-03_
