# Capacity Manager Agent — Operator Guide

> Status: **seeded** (HIER-P2B, Phase 2 wave 2 — 2026-09-03). HIER-P2DECL (wave 1) declared
> the policy set, identity, sensor ownership and hierarchy seat; this wave added the seed
> file (prompt, routing description, tool-family scope, approval chain, trust score) and
> re-bound the capacity executors to the agent.

The **Capacity Manager** is one of the twelve official system-extension agents. It owns fleet **capacity**: disaster-recovery replacement of unrecoverable instances, cost-bearing expansion, workload relocation, warm instance pools, the `project.*` provisioning / adaptation verbs, platform-deployment scaling and the cordon. Split out of Fleet Autonomy on 2026-09-03 (HIER-P2DECL, Phase 2 wave 1) so capacity decisions have an independent queue from the node-lifecycle remediation core.

Source of truth: `System::Governance::PolicyDeclarations::CAPACITY_MANAGER_POLICIES` (identity
`"capacity-manager"` in `PolicyDeclarations::AGENT_IDENTITIES`, name `"Capacity Manager"`, type
`monitor`). Seed: `db/seeds/system_capacity_manager_agent.rb` — a GLOBAL canonical
(`System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent`, which refuses to adopt a
stray account-scoped row of the same name), attached under the System Concierge by
`db/seeds/system_agent_hierarchy.rb` with the P1 leaf delegation (conservative, `max_depth` 2,
no delegate types). On a FRESH install the seed writes the 22 rows below at the agent shape
(`project.scale_horizontal` with its `auto_apply_window` condition override); on an
ESTABLISHED install — `db:seed` is first-boot only — `PolicyReconciler` **re-homes** every
row below that Fleet Autonomy already holds, in place, verb / `is_active` / conditions /
priority preserved, a `system.intervention_policy.rehomed` audit row written, from the
`PolicyReconciler::FORMER_OWNERS` map.

The two first-boot policy seeds that carry fourteen of those rows —
`db/seeds/system_instance_pool_policies.rb` (the eight `system.instance_pool_*`) and
`db/seeds/system_provisioning_intervention_policies.rb` (the six `project.*`) — write onto
**this agent**, not Fleet Autonomy (HIER-P2B). That is not cosmetic: both run AFTER this
seed in `SYSTEM_SEED_FILES`, and `PolicyReconciler#reconcile!` answers `present` and never
consults `rehomable_row` for a category the owner already has — so a row they left on Fleet
Autonomy on a fresh install would be an active agent-scope control no gate ever reads, with
nothing to collect it (`clean_unregistered_policies!` only collects DEREGISTERED categories).
Pinned by `spec/services/system/fleet/routed_lane_policy_coherence_spec.rb`, which loads the
seeds in `SYSTEM_SEED_FILES` order.

---

## Charter

The agent reconciles **capacity, not health**. Fleet Autonomy runs the sensor tick and
remediates a sick node (reboot, reprovision, drift, certificates, rolling upgrades); the
Capacity Manager acts when the fleet is the wrong **size** or in the wrong **place**:

- **Desired vs live replicas.** A platform deployment's `target_replicas` is intent; the
  live count is `active.not_cordoned` — one scope pair owned by
  `System::InstanceCordonService`, read identically by `System::Platform::ReplicaReconciler`
  and the Scaling panel (IMP-3d4058389afa). A cordoned replica is out of the live count (so
  its replacement is provisioned) and the first scale-in victim (IMP-c9adb5a71dca).
- **Control-plane self-protection.** The replica reconciler refuses the deployment hosting
  this control plane (`control_plane_self_remediation`); the agent's prompt carries the same
  rule: never scale in the deployment hosting the control plane. Scale-OUT auto-executes only
  inside the deployment's declared window (`PlatformDeployment#scaling_bounds`); scale-IN is
  gated.
- **Pool ceilings are spend commitments.** `replenish` tops a pool up to target on its own;
  raising target/max, creating, deleting, archiving or draining a pool are gated.
- **Provider quota and region availability are facts, not retries** — a provider refusal is
  reported with the region, instance type and count named. Every cost-bearing verb
  (`region_expansion`, `capacity_resize`, `relocate_workload`, `project.relocate`) is gated.
- **Cordon semantics.** A cordon marks an instance unschedulable and leaves it running; a
  ready pool member is fenced (`pool_state=draining`), a claimed member is fenced on return,
  a non-pool instance is marked only. Uncordon re-admits a fenced member only while it is
  still running. Both verbs share `system.instance_cordon`; the agent never lifts a cordon an
  operator placed for maintenance.
- **Replace is additive; the reap is a second decision.** An approved
  `system.instance_replace` leaves the replacement in service and the dead row visible;
  `system.instance_reap` terminates it under its own approval.

Twin of three operator-only sets, which keep their rows: `instance-pool-operator` (the four gated pool verbs at the global shape), `platform-scaling` and `instance-cordon-operator`. The agent shape carries all eight pool verbs; the operator shape only the four a gate site passes (IMP-5a2b801f3386).

**Hand-offs:** volumes / snapshots / restore → **Storage Manager**; published services,
ACME, service backends → **Ingress Manager**; packages, modules, the architecture catalog →
**Supply Chain Manager**; reboot / reprovision / terminate remediation, drift, certs, rolling
upgrades, replica promotion → **Fleet Autonomy**; the overlay → **SDWAN Manager**; Docker /
K3s → **Runtime Manager**; operator chat and platform deploy → **System Concierge**.

---

## Skills

Six executors bind to the agent (`binds_to "capacity_manager"` — the
`SkillBindings::AGENT_ALIASES` slug; `system_skill_bindings_seed.rb` materialises the
`Ai::AgentSkill` rows and deletes drift):

| Skill | Executor | Gate | Previously |
|---|---|---|---|
| `system-replace-instance` | `ReplaceInstanceExecutor` | `system.instance_replace` (require_approval) — the `instance_unrecoverable_sensor` lane runs it AS this agent | Fleet Autonomy |
| `system-reap-instance` | `ReapInstanceExecutor` | `system.instance_reap` (require_approval) — the second approval a replace asks for | Fleet Autonomy |
| `system-relocate-workload` | `RelocateWorkloadExecutor` | `system.relocate_workload` (require_approval) | Fleet Autonomy |
| `system-scale-project` | `ScaleProjectExecutor` | dispatched by `System::AdaptationGate` under `project.scale_horizontal` (auto within the `auto_apply_window`); `remove_replicas` is approval-gated by the result envelope | Fleet Autonomy |
| `system-provision-full-stack` | `ProvisionFullStackExecutor` | the composer `scale_project` / `relocate_workload` call | Fleet Autonomy |
| `system-platform-resilience` | `PlatformResilienceExecutor` | `scale` resolves `system.platform.scale_out` / `scale_in` through `ReplicaReconciler` against the executing agent; `drain_instance` is the cordon + stop | System Concierge (kept — the operator chat door) |

Not moved: `promote_replica` (`system.replica_promote` stays a Fleet Autonomy category) and
`capacity_recommend` (read-shape, System Concierge; it only *proposes* a
`system.capacity_resize`).

Tool access (`mcp_metadata.tool_access.tool_families`) lists only the capacity families —
instance verbs, instance-pool verbs, node / template reads, `system_platform_resilience`,
provider reads, task reads, storage reads — so the Claude Code counterpart
(`.claude/agents/powernode/capacity-manager.md`, `rake claude:sync_agents`) carries a scoped
`tools:` allowlist rather than the full read set.

---

## Intervention Policies

The agent ships with **22 intervention policies**:

| Action | Policy | Reached through | Why |
|---|---|---|---|
| `system.instance_replace` | `require_approval` | sensor: `instance_unrecoverable_sensor` → `ReplaceInstanceExecutor` | Disaster recovery for an instance a reboot cannot recover; separate from Fleet Autonomy's `system.instance_reprovision` |
| `system.instance_reap` | `require_approval` | executor: `ReapInstanceExecutor` (second approval asked by the replace) | The destructive half of a replace, split out so it can be refused while the additive half proceeds |
| `system.region_expansion` | `require_approval` | executor / Concierge | Cost-bearing |
| `system.capacity_resize` | `require_approval` | executor / Concierge (`capacity_recommend` proposes) | Cost-bearing |
| `system.relocate_workload` | `require_approval` | executor: `RelocateWorkloadExecutor` | Workload relocation |
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
| `project.scale_horizontal` | `auto_approve` | `AdaptationGate` → `ScaleProjectExecutor` (bounded by the `auto_apply_window` condition override) | Replica adjust within the auto-scale ceiling |
| `project.relocate` | `require_approval` | `AdaptationGate` | Cross-region move |
| `project.schema_change` | `require_approval` | `AdaptationGate` | Storage / schema mutation |
| `project.security_change` | `require_approval` | `AdaptationGate` | SDWAN / firewall change |
| `system.platform.scale_out` | `auto_approve` | `System::Platform::ReplicaReconciler` — twin; read at this shape when `platform_resilience` runs AS this agent | Auto-executes inside the deployment's declared window, parks otherwise |
| `system.platform.scale_in` | `require_approval` | `ReplicaReconciler` — twin | Terminates instances — not reversible |
| `system.instance_cordon` | `require_approval` | `SystemFleetTool` cordon / uncordon — twin | Takes capacity out of / back into scheduling |

"Reached through" is the door whose gate resolves the row: a **sensor** lane is
gated on the Fleet Autonomy tick under this agent (HIER-P2A owner gating —
`FleetAutonomyService#for_owner("capacity-manager")` resolves this agent and runs the
executor as it); an **executor** resolves it in `BaseSkillExecutor#execute` against the
EXECUTING agent, which since HIER-P2B is this one for every executor in the table above;
a **twin** row is read only when the MCP / REST verb is called AS this agent, and the
operator row in the paired operator set is what an operator's own call resolves.

### Tuning a policy

```ruby
# rails console
agent = Ai::Agent.global.find_by(name: "Capacity Manager")
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

`Capacity Manager Actions` (`trigger_type: autonomy_action`, sequential, one step —
`Capacity Operator Approval`, approver permission `system.infra_tasks.control`, 4-hour
timeout, **reject** on timeout). `FleetAutonomyService#fleet_approval_chain` resolves the
chain by the owner agent's name, so a pending request for one of these categories lands
here rather than on `Fleet Autonomy Actions`. Trust bootstrap: tier `monitored`, overall
0.72 (`safety` 0.88 — the verbs are cost-bearing and often irreversible).

---

## Related Documents

- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) §Intervention Policy Reference — the per-agent census this table is pinned against (`spec/docs/reference_counts_spec.rb`)
- [`SKILL_EXECUTORS.md`](./SKILL_EXECUTORS.md) — the executor reference and the binding table
- [`runbooks/instance-pool-tuning.md`](./runbooks/instance-pool-tuning.md), [`runbooks/node-provisioning.md`](./runbooks/node-provisioning.md) — the pool ceilings and the cordon / drain semantics this agent enforces
- [`CLAUDE.md`](../CLAUDE.md) — index of all extension agents, including this one
- `spec/db/seeds/system_capacity_manager_agent_seed_spec.rb` — the seed contract (canonical row, policies, chain, hierarchy seat, bindings)
- `docs/reference/system-agent-hierarchy-proposal-2026-09-03.md` (core tree) — the Phase 2 rulings this agent comes from

_Last verified: 2026-09-03_
