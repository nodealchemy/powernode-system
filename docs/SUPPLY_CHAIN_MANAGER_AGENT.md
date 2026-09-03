# Supply Chain Manager Agent — Operator Guide

> Status: **seeded** (HIER-P2E, Phase 2 wave 2 — 2026-09-03). Declared in wave 1
> (HIER-P2DECL: policy set, identity, sensor ownership, hierarchy seat); the seed file,
> prompt, approval chain, trust score, tool scope and skill bindings land here.

The **Supply Chain Manager** is one of the twelve official system-extension agents. It owns the **software supply chain**: package repository ingestion, package-derived module creation and refresh, and the architecture catalog. Split out of Fleet Autonomy on 2026-09-03 (HIER-P2DECL, Phase 2 wave 1; seeded by HIER-P2E, wave 2). CVE response stays with the CVE Responder.

Source of truth: `System::Governance::PolicyDeclarations::SUPPLY_CHAIN_MANAGER_POLICIES` (identity
`"supply-chain-manager"` in `PolicyDeclarations::AGENT_IDENTITIES`, name `"Supply Chain Manager"`, type
`monitor`). Seed: `server/db/seeds/system_supply_chain_manager_agent.rb`, which writes the
**agent** (global canonical, `source_key: "supply-chain-manager"`), its **trust score**
(monitored, 0.70) and its **approval chain** — and deliberately **no policy row**:
`PolicyReconciler` writes this set onto the agent (boot-time `governance-reconcile`, or
`rails system:governance:reconcile`), creating the seven rows on a fresh install and
**re-homing** every row below that an established install already holds on Fleet
Autonomy — in place, verb / `is_active` / conditions / priority preserved, a
`system.intervention_policy.rehomed` audit row written — from the
`PolicyReconciler::FORMER_OWNERS` map. (A seed upsert would leave the old row behind: the
reconciler does not touch a former owner's row once the new owner has its own.)

---

## Charter

Every package that enters the fleet passes through this agent, and every one of them is
operator-audited: materialising a package as a NodeModule (`system.package_module.create`)
is `require_approval`, always. Repository metadata sync is routine (`auto_approve`). The
architecture catalog is shared by every account, so direct create / update / delete is
gated even for a holder of `system.architectures.manage`; `architecture_propose` is
auto-approved because the `Ai::AgentProposal` it files is itself the review.

The prompt carries provenance / SBOM / VEX awareness: an artifact's ingested SBOM is the
evidence of what a module ships, a CVE / VEX statement is the evidence of what that
means, and a package-name match with no version evidence is a suspicion, not a fact.

No operator twin: none of these has an operator-only set.

**Hand-offs** (the seeded system prompt names them, and the platform router reads the
full `description`; the Claude Code counterpart's own "Do not use for …" clause is
GENERATED from its sibling agents by `Ai::ClaudeExport::RoutingDescription`, not lifted
from this text):

| Topic | Goes to |
|---|---|
| CVE exposure, triage, patch rollout | **CVE Responder** (`system.cve_*`); it calls this agent's refresh executor directly when a fix exists |
| Disk-image publications, promotion, rollback, retention | **Disk Image Manager** |
| Module composition onto templates, module version promotion, rolling upgrades | **Fleet Autonomy** |
| Operator chat, `discover_packages_by_intent` | **System Concierge** |

---

## Intervention Policies

The agent ships with **7 intervention policies**:

| Action | Policy | Reached through | Why |
|---|---|---|---|
| `system.package_repository.sync` | `auto_approve` | sensor: `package_drift_sensor` → `DecisionEngine#sync_package_repository` (enqueues `PackageRepositorySyncService`); executor: `PackageRepositorySyncExecutor` | Routine PackageRepository refresh |
| `system.package_module.create` | `require_approval` | executor: `PackageModuleCreateExecutor` | Materialises a NodeModule from a PackageRepository — supply-chain critical |
| `system.package_module.refresh` | `require_approval` | executor: `PackageModuleRefreshExecutor` (invoked directly by the CVE lane; no binding routes here) | Re-resolves dependencies / re-validates manifest |
| `system.architecture.propose` | `auto_approve` | executor: `ArchitectureProposeExecutor` | The `Ai::AgentProposal` it creates is itself the human-review gate |
| `system.architecture.create` | `require_approval` | executor: `ArchitectureCreateExecutor` | Catalog change — affects every account's available platforms |
| `system.architecture.update` | `require_approval` | executor: `ArchitectureUpdateExecutor` | Catalog change |
| `system.architecture.delete` | `require_approval` | executor: `ArchitectureDeleteExecutor` | Catalog change |

"Reached through" is the door whose gate resolves the row: a **sensor** lane is
gated on the Fleet Autonomy tick under this agent (HIER-P2A owner gating —
`FleetAutonomyService#for_owner("supply-chain-manager")`); an **executor** resolves it in
`BaseSkillExecutor#execute` when run as this agent (the executors above `binds_to
"supply_chain_manager"` since HIER-P2E, so the Concierge and the skill router run them as
this agent and the gate reads this agent's row).

### The CVE lane and `package_module_refresh`

Nothing sensor-routed reaches `PackageModuleRefreshExecutor`. Its only orchestrated caller
is `CveRemediationOrchestrationExecutor#dispatch_refreshes` (the **CVE Responder**), which
builds the executor directly for each exposed module and runs it under the CVE lane's own
gate — so the CVE Responder **keeps** its `system-package-module-refresh` binding beside
this agent's. The `system.package_module.refresh` row here is read when the refresh is
run AS the Supply Chain Manager (skill router / Concierge delegation), where it requires
approval; the CVE lane does not consult it.

### Tuning a policy

```ruby
# rails console
agent = Ai::Agent.global.find_by(source_key: "supply-chain-manager")
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

## Skills

Re-bound from Fleet Autonomy by HIER-P2E (`binds_to "supply_chain_manager"`;
`system_skill_bindings_seed.rb` materialises the rows and deletes the stale Fleet
Autonomy ones):

| Skill | Also bound to | Notes |
|---|---|---|
| `system-package-repository-sync` | — | the sensor path gates the same category under this agent |
| `system-package-module-create` | System Concierge | `require_approval` |
| `system-package-module-refresh` | System Concierge, **CVE Responder** | CVE lane invokes it directly (above) |
| `system-architecture-propose` | — | auto-approved; the proposal is the gate |
| `system-architecture-create` / `-update` / `-delete` | — | `require_approval` |
| `system-suggest-architectures-for-fleet` | System Concierge | read-shape; no gate |

`system-discover-packages-by-intent` stays with Fleet Autonomy + System Concierge (it is
a read-shaped discovery skill that module composition consumes).

---

## Tool scope

`mcp_metadata.tool_access.tool_families` lists only the registry actions this agent
needs — `Ai::AgentToolBridgeService#scope_to_tool_families` and
`Ai::ClaudeExport::ToolAllowlist` read the same list, so the platform tool bridge and the
Claude Code `tools:` allowlist agree:

- package repositories: `system_list_package_repositories`, `system_get_package_repository`, `system_create_package_repository`, `system_update_package_repository`, `system_sync_package_repository`
- packages: `system_search_packages`, `system_discover_packages`, `system_get_package`, `system_resolve_package_dependencies`
- package modules: `system_list_package_module_links`, `system_create_module_from_package`, `system_refresh_package_module`
- architectures: `system_list_architectures`, `system_get_architecture`, `system_propose_architecture`, `system_create_architecture`, `system_update_architecture`, `system_delete_architecture`, `system_suggest_architectures_for_fleet`
- modules (read): `system_list_modules`, `system_get_module`, `system_list_module_versions`, `system_discover_modules`, `system_validate_module_manifest`
- CVE (read): `system_get_cve`, `system_get_cve_exposure`

Absent on purpose: SDWAN, disk images, module promotion / rollback, CVE writes,
`system_delete_package_repository`.

---

## Approval Chain

`Supply Chain Manager Actions` (`trigger_type: autonomy_action`, sequential, one step,
`system.infra_tasks.control` approver, **8-hour** timeout, **reject** on timeout — a
package audit spans business hours and never auto-proceeds).
`FleetAutonomyService#for_owner` resolves the chain by the owner agent's name, so a
pending `system.package_repository.sync` decision lands here, not on
`Fleet Autonomy Actions`.

---

## Hierarchy

Attached under **System Concierge** by `db/seeds/system_agent_hierarchy.rb`
(`HierarchyReconciler`): one active lineage edge (`spawn_reason: "seed"`) and the P1 leaf
delegation (conservative, `max_depth` 2, no delegate types). Model: reasoning tier via
`model_config.model_requirements` — no pinned provider or model.

---

## Related Documents

- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) §Intervention Policy Reference — the per-agent census this table is pinned against (`spec/docs/reference_counts_spec.rb`)
- [`SKILL_EXECUTORS.md`](./SKILL_EXECUTORS.md) — agent → skill binding map
- [`runbooks/cve-response.md`](./runbooks/cve-response.md) — the lane that calls `package_module_refresh`
- [`CLAUDE.md`](../CLAUDE.md) — index of all extension agents, including this one
- `docs/reference/system-agent-hierarchy-proposal-2026-09-03.md` (core tree) — the Phase 2 rulings this agent comes from
- `spec/db/seeds/system_supply_chain_manager_agent_seed_spec.rb` — pins everything above

_Last verified: 2026-09-03_
