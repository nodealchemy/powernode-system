# Ingress Manager Agent — Operator Guide

> Status: **declared, not yet seeded** (HIER-P2DECL, Phase 2 wave 1 — 2026-09-03). The
> policy set, identity, sensor ownership and hierarchy seat are declared; the agent
> itself (seed file, prompt, approval chain, trust score, skill bindings) lands in
> wave 2. This page carries the table wave 2 fills in.

The **Ingress Manager** is one of the twelve official system-extension agents. It owns **service exposure and certificate issuance**: the local `/svc/<slug>` publish, public TCP and HTTPS exposure, ACME DNS-01 issuance, and the backend set of a published service. Split out of Fleet Autonomy on 2026-09-03 (HIER-P2DECL, Phase 2 wave 1). `system.service_backends_update` travels with this group because the agent that owns the ingress writer owns the row that gates it (the decision HIER-P2A deferred).

Source of truth: `System::Governance::PolicyDeclarations::INGRESS_MANAGER_POLICIES` (identity
`"ingress-manager"` in `PolicyDeclarations::AGENT_IDENTITIES`, name `"Ingress Manager"`, type
`monitor`). There is no seed file yet: `PolicyReconciler` writes this set onto
the agent on the first boot after wave 2 seeds it, and **re-homes** every row
below that an established install already holds on Fleet Autonomy — in place,
verb / `is_active` / conditions / priority preserved, a
`system.intervention_policy.rehomed` audit row written — from the
`PolicyReconciler::FORMER_OWNERS` map.

---

## Charter

No operator twin: none of these has an operator-only set. **No sensor routes to any of these categories** — every row gates an executor / MCP door (`sensor_owner_gating_spec` asserts this rather than assuming it), so this agent owns rows but, today, no sensor lane.

**Until wave 2 seeds the agent:** every `DecisionEngine::SIGNAL_BINDINGS` entry
that declares `owner: "ingress-manager"` gates under **Fleet Autonomy** with a
`fleet.owner_agent_missing` event (`FleetAutonomyService#for_owner`), where an
established install still holds the rows. `PolicyReconciler` reports the set as
`ingress-manager(agent absent)` in its drift report, and
`System::Governance::HierarchyReconciler` reports the missing Concierge child the
same way — drift, not an error.

---

## Intervention Policies

The agent ships with **5 intervention policies**:

| Action | Policy | Reached through | Why |
|---|---|---|---|
| `system.expose_service_local` | `require_approval` | executor: `ExposeServiceLocalExecutor` | Publishes a service at `/svc/<slug>` behind ForwardAuth |
| `system.expose_service_public_tcp` | `require_approval` | executor: `ExposeServicePublicTcpExecutor` | Public TCP exposure (VIP + port map) |
| `system.expose_service_publicly` | `require_approval` | executor: `ExposeServicePubliclyExecutor` | Public HTTPS exposure (VIP → port map → ACME → Traefik) |
| `system.acme_certificate_provision` | `require_approval` | executor: `AcmeCertificateProvisionExecutor` | DNS-01 certificate issuance |
| `system.service_backends_update` | `require_approval` | `Ai::Tools::SystemIngressTool#system_set_service_backends` | Declares a published service's backend set (the list IS the set; `[]` clears); a wrong set blackholes the service |

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
agent = Ai::Agent.find_by(name: "Ingress Manager")
Ai::InterventionPolicy.find_by(
  ai_agent_id: agent.id, action_category: "system.expose_service_local"
).update!(policy: "notify_and_proceed")
```

`PolicyReconciler` is absence-only: a tuned verb is never reset by a boot.

---

## Sensor → Action Map

| Sensor | Signal | Triggers action | Policy default |
|---|---|---|---|
| — | none | — | — |

See [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) for sensor implementation details.

---

## Approval Chain

Wave 2 seeds the `Ingress Manager Actions` chain (`trigger_type: autonomy_action`).
`FleetAutonomyService#for_owner` resolves the chain by the owner agent's name, so
until it exists a pending request for one of these categories lands on the
fallback agent's chain (`Fleet Autonomy Actions`).

---

## Related Documents

- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) §Intervention Policy Reference — the per-agent census this table is pinned against (`spec/docs/reference_counts_spec.rb`)
- [`CLAUDE.md`](../CLAUDE.md) — index of all extension agents, including this one
- `docs/reference/system-agent-hierarchy-proposal-2026-09-03.md` (core tree) — the Phase 2 rulings this agent comes from

_Last verified: 2026-09-03_
