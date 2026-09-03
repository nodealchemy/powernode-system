# Supply Chain Manager Agent — Operator Guide

> Status: **declared, not yet seeded** (HIER-P2DECL, Phase 2 wave 1 — 2026-09-03). The
> policy set, identity, sensor ownership and hierarchy seat are declared; the agent
> itself (seed file, prompt, approval chain, trust score, skill bindings) lands in
> wave 2. This page carries the table wave 2 fills in.

The **Supply Chain Manager** is one of the twelve official system-extension agents. It owns the **software supply chain**: package repository ingestion, package-derived module creation and refresh, and the architecture catalog. Split out of Fleet Autonomy on 2026-09-03 (HIER-P2DECL, Phase 2 wave 1). CVE response stays with the CVE Responder.

Source of truth: `System::Governance::PolicyDeclarations::SUPPLY_CHAIN_MANAGER_POLICIES` (identity
`"supply-chain-manager"` in `PolicyDeclarations::AGENT_IDENTITIES`, name `"Supply Chain Manager"`, type
`monitor`). There is no seed file yet: `PolicyReconciler` writes this set onto
the agent on the first boot after wave 2 seeds it, and **re-homes** every row
below that an established install already holds on Fleet Autonomy — in place,
verb / `is_active` / conditions / priority preserved, a
`system.intervention_policy.rehomed` audit row written — from the
`PolicyReconciler::FORMER_OWNERS` map.

---

## Charter

No operator twin: none of these has an operator-only set.

**Until wave 2 seeds the agent:** every `DecisionEngine::SIGNAL_BINDINGS` entry
that declares `owner: "supply-chain-manager"` gates under **Fleet Autonomy** with a
`fleet.owner_agent_missing` event (`FleetAutonomyService#for_owner`), where an
established install still holds the rows. `PolicyReconciler` reports the set as
`supply-chain-manager(agent absent)` in its drift report, and
`System::Governance::HierarchyReconciler` reports the missing Concierge child the
same way — drift, not an error.

---

## Intervention Policies

The agent ships with **7 intervention policies**:

| Action | Policy | Reached through | Why |
|---|---|---|---|
| `system.package_repository.sync` | `auto_approve` | sensor: `package_drift_sensor` → `DecisionEngine#sync_package_repository` (enqueues `PackageRepositorySyncService`) | Routine PackageRepository refresh |
| `system.package_module.create` | `require_approval` | executor: `PackageModuleCreateExecutor` | Materialises a NodeModule from a PackageRepository — supply-chain critical |
| `system.package_module.refresh` | `require_approval` | executor: `PackageModuleRefreshExecutor` (invoked directly by the CVE lane; no binding routes here) | Re-resolves dependencies / re-validates manifest |
| `system.architecture.propose` | `auto_approve` | executor: `suggest_architectures_for_fleet` | The `Ai::AgentProposal` it creates is itself the human-review gate |
| `system.architecture.create` | `require_approval` | executor: architecture CRUD | Catalog change — affects every account's available platforms |
| `system.architecture.update` | `require_approval` | executor: architecture CRUD | Catalog change |
| `system.architecture.delete` | `require_approval` | executor: architecture CRUD | Catalog change |

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
agent = Ai::Agent.find_by(name: "Supply Chain Manager")
Ai::InterventionPolicy.find_by(
  ai_agent_id: agent.id, action_category: "system.package_repository.sync"
).update!(policy: "require_approval")
```

`PolicyReconciler` is absence-only: a tuned verb is never reset by a boot.

---

## Sensor → Action Map

| Sensor | Signal | Triggers action | Policy default |
|---|---|---|---|
| `package_drift_sensor` | `system.package_drift_pressure` | `system.package_repository.sync` | `auto_approve` |

See [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) for sensor implementation details.

---

## Approval Chain

Wave 2 seeds the `Supply Chain Manager Actions` chain (`trigger_type: autonomy_action`).
`FleetAutonomyService#for_owner` resolves the chain by the owner agent's name, so
until it exists a pending request for one of these categories lands on the
fallback agent's chain (`Fleet Autonomy Actions`).

---

## Related Documents

- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) §Intervention Policy Reference — the per-agent census this table is pinned against (`spec/docs/reference_counts_spec.rb`)
- [`CLAUDE.md`](../CLAUDE.md) — index of all extension agents, including this one
- `docs/reference/system-agent-hierarchy-proposal-2026-09-03.md` (core tree) — the Phase 2 rulings this agent comes from

_Last verified: 2026-09-03_
