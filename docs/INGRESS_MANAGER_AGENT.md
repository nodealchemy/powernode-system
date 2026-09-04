# Ingress Manager Agent — Operator Guide

> Status: **active** (seeded by HIER-P2D, Phase 2 wave 2 — 2026-09-03; declared by HIER-P2DECL, wave 1).

The **Ingress Manager** is one of the twelve official system-extension agents. It owns **service exposure and certificate issuance**: the local `/svc/<slug>` publish, public TCP and HTTPS exposure, ACME DNS-01 issuance, and the backend set of a published service. Split out of Fleet Autonomy on 2026-09-03 (HIER-P2DECL, Phase 2 wave 1). `system.service_backends_update` travels with this group because the agent that owns the ingress writer owns the row that gates it (the decision HIER-P2A deferred).

Source of truth: `System::Governance::PolicyDeclarations::INGRESS_MANAGER_POLICIES` (identity
`"ingress-manager"` in `PolicyDeclarations::AGENT_IDENTITIES`, name `"Ingress Manager"`, type
`monitor`). Seed: `db/seeds/system_ingress_manager_agent.rb` — a GLOBAL seeded canonical
(`AgentSetupHelpers.find_or_initialize_global_agent`, which refuses to adopt a stray
account-scoped row), attached under the System Concierge by `db/seeds/system_agent_hierarchy.rb`
with the P1 leaf delegation (conservative, max depth 2, no delegate types). The seed writes
the agent's identity, trust score and approval chain and NO policy row (IMP-10e4f6c3bcd2,
proposal §5 ruling 7); `PolicyReconciler` is the single writer of the set, on every boot
including the first (the seed orchestrator ends with
`db/seeds/system_governance_policy_reconcile.rb`), and it **re-homes** any row an
established install still holds on Fleet Autonomy — in place,
verb / `is_active` / conditions / priority preserved, a `system.intervention_policy.rehomed`
audit row written — from the `PolicyReconciler::FORMER_OWNERS` map.

---

## Charter

No operator twin: none of these has an operator-only set. **No sensor routes to any of these categories** — every row gates an executor / MCP door (`sensor_owner_gating_spec` asserts this rather than assuming it), so this agent owns rows but no fleet-tick lane. It acts when an operator asks — through the System Concierge (which routes the chat and carries the inline approval card) or through an MCP door — for a service to be published, exposed, certified or re-pointed.

**Model:** reasoning tier via `mcp_metadata.model_config.model_requirements` (an exposure decision reads a service, a certificate, a VIP and a backend set together); no pinned provider or model — `Ai::AgentModelSelector` resolves it. **Trust:** starts `monitored` (0.70): every verb it owns is an exposure or a backend-set write (blackhole class).

### Skills bound (4)

Re-bound by HIER-P2D from `binds_to "System Concierge"` (and, for the ACME executor, `"Fleet Autonomy"`) to `binds_to "ingress_manager", "System Concierge"` — the Concierge keeps the operator-chat door, and `BaseSkillExecutor` resolves each executor's gate against the **executing** agent, so a row tuned on this agent applies when it runs as this agent. Materialised by `system_skill_bindings_seed.rb`.

| Skill | Executor | Gate |
|---|---|---|
| `system-expose-service-local` | `ExposeServiceLocalExecutor` | `system.expose_service_local` |
| `system-expose-service-publicly` | `ExposeServicePubliclyExecutor` | `system.expose_service_publicly` |
| `system-expose-service-public-tcp` | `ExposeServicePublicTcpExecutor` | `system.expose_service_public_tcp` |
| `system-acme-certificate-provision` | `AcmeCertificateProvisionExecutor` | `system.acme_certificate_provision` |

Fleet Autonomy is **dropped** from the ACME executor: no `DecisionEngine::SIGNAL_BINDINGS` entry routes to it. The sensor-routed `system.acme_cert_expiring` → `system.acme_cert_rotate` lane fires `PlatformMaintenanceExecutor`'s `cert_rotate` renewal sweep and stays Fleet Autonomy's (below). There is no `unexpose` executor: `system_unexpose_service_local` / `system_unexpose_service_public_tcp` are MCP actions (fail-safe OFF, ungated) — the second is `ExposeServicePublicTcpExecutor` with `enabled: false`.

### Tool families (`mcp_metadata.tool_access.tool_families`)

HIER-P1B derives the Claude Code `tools:` allowlist from this list (`Ai::ClaudeExport::ToolAllowlist`), and `Ai::AgentToolBridgeService` scopes the runtime tool list the same way; an entry matches a registered action by exact name or `<family>_` prefix, and the seed spec pins every entry against the registry (a list that matches nothing fails open to the full registry).

| Family | Registered actions it admits |
|---|---|
| `system_list_services`, `system_get_service`, `system_create_service` | service reads + the create door |
| `system_set_service_backends` | the gated backend-set door |
| `system_expose_service`, `system_unexpose_service` | `system_expose_service_{local,publicly,public_tcp}`, `system_unexpose_service_{local,public_tcp}` |
| `system_acme_provision_certificate`, `system_acme_get_certificate` | DNS-01 issuance and the certificate read — named in full, **not** the `system_acme` family |
| `system_sdwan_list_virtual_ips`, `system_sdwan_get_virtual_ip`, `system_sdwan_list_vip_assignments` | VIP **reads** — the lifecycle (create / failover / delete) stays the SDWAN Manager's |
| `system_reverse_proxy_compose` | repair a stale proxy file after a regen failure |
| `discover_skills`, `get_skill_context`, `search_knowledge`, `query_learnings` | the discovery/knowledge reads `BASE_GUARDRAILS` order every agent to make |

### What the list deliberately keeps OUT

A family entry matches by `<family>_` **prefix**, so a bare family silently widens the grant. Three writes are excluded on purpose:

- **the bare `system_acme` family** — it would admit `system_acme_renew_certificate`, `system_acme_revoke_certificate` and `system_acme_create_dns_credential`. All three are `mutating: true` with **no** `action_category` and appear in no `POLICY_SETS` entry, so nothing downstream gates them: revoking a live certificate takes an HTTPS route dark with no approval card, and a DNS-01 credential is secret-bearing. Renewal is Fleet Autonomy's lane in any case (below).
- **`system_update_service`** — `SystemIngressTool#update_service` writes `backend_vip_id` / `backend_host` / `backend_port` and regenerates the proxy when the service is exposed. That is the same blackhole blast radius the **gated** `system_set_service_backends` exists to control, with no gate on it, so it stays an operator door.
- **`system_delete_service`** — unpublishing is the unexpose verbs; deleting the record is an operator door.

The discovery/knowledge entries no longer need to be listed defensively: since HIER-P2H both the Claude Code exporter and `Ai::AgentToolBridgeService#scope_to_tool_families` union the shared `Ai::Tools::BootstrapVerbs::ACTIONS` onto every scoped family list, so a families list that omits them still keeps the tools `BASE_GUARDRAILS` orders the agent to call.

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

"Reached through" is the door whose gate resolves the row: an **executor** resolves it in
`BaseSkillExecutor#execute` when run as this agent (run as the System Concierge from operator
chat, the same category resolves the Concierge's rows and falls to the `require_approval`
default — the verdict these rows declare, so the door parks an approval either way); the **MCP**
row is read only when `system_set_service_backends` is called AS this agent, and an operator's
own call resolves the unmatched `require_approval` default.

### Tuning a policy

```ruby
# rails console
agent = Ai::Agent.global.find_by(name: "Ingress Manager")
Ai::InterventionPolicy.find_by(
  ai_agent_id: agent.id, action_category: "system.expose_service_local"
).update!(policy: "notify_and_proceed")
```

`PolicyReconciler` is absence-only: a tuned verb is never reset by a boot.

---

## What the prompt carries (the runbook behind the verbs)

- **Publish** — resolve-or-create the `Sdwan::Service`, enable the facet, `Sdwan::ServiceExposureWriter` regenerates `local-services-<account>.yaml`, Traefik hot-reloads. Runbook: [`runbooks/publish-service.md`](./runbooks/publish-service.md); the public sibling is [`runbooks/expose-service.md`](./runbooks/expose-service.md).
- **Backend set (IMP-0c10b9fd5596)** — the `backends` list IS the set (`[]` clears); a `draining` member leaves the emitted server list; **draining every member takes the service out of rotation** (the writer skips it under `drained_service_ids`, `system_set_service_backends` answers `out_of_rotation: true`, the local expose skill fails instead of reporting a `local_url` nothing serves); an empty set is a different state and renders the legacy backend. The fleet executors (`scale_project`, `replace_instance`, `reap_instance`) maintain the set by address; a VIP-fronted service is left to the VIP move.
- **Health checks are opt-in (tier 1)** — `health_check_enabled` defaults to `false` because a check pointed at the wrong path takes the whole service dark (Traefik answers 503 once no server passes). Enable per service through `load_balancer` on the gated verb; a lower tier beats a higher one and `false` counts as a value.
- **ACME split** — issuance is this agent's (`system.acme_certificate_provision`); **renewal stays Fleet Autonomy's** (`system.acme_cert_rotate`, `notify_and_proceed`): `CertExpirySensor` runs on the fleet tick and fires the `platform_maintenance` `cert_rotate` sweep over certificates the platform already holds — a fleet-health remediation with no issuance decision in it. Runbook: [`runbooks/acme-issuance.md`](./runbooks/acme-issuance.md).
- **Hand-offs** — networks, peers and VIP lifecycle → **SDWAN Manager**; replica counts → **Capacity Manager** (new replicas join the set by address on their own); node-level cert rotation → **Fleet Autonomy**.

---

## Sensor → Action Map

| Sensor | Signal | Triggers action | Policy default |
|---|---|---|---|
| — | none | — | — |

See [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) for sensor implementation details.

---

## Approval Chain

`Ingress Manager Actions` (`trigger_type: autonomy_action`, sequential, one approval by
`system.infra_tasks.control`, **4-hour** timeout, reject on timeout — exposure changes are
operator-visible and reversible, so a publish request that waits half a day is stale).
`FleetAutonomyService#for_owner` resolves the chain by the owner agent's name.

---

## Claude Code counterpart

`.claude/agents/powernode/ingress-manager.md` (core tree) is the exported subagent skeleton
(`rake claude:sync_agents`, freshness-gated by `scripts/check-claude-agents-fresh.sh`). The
`tools:` allowlist comes from the tool families above (plus `ToolAllowlist::BOOTSTRAP_ACTIONS`).
The frontmatter description does **not** ship this page's routing description verbatim:
`Ai::ClaudeExport::RoutingDescription#build` keeps only its **first sentence** (truncated to 140
chars) and replaces the "Do not use for …" clause with a **machine-derived** exclusion naming
whichever sibling the exporter picks — so the SDWAN Manager / Capacity Manager / Fleet Autonomy
exclusions reach the platform router and this page, not the skeleton. The first sentence is
written to stand alone as the trigger for that reason.

---

## Related Documents

- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) §Intervention Policy Reference — the per-agent census this table is pinned against (`spec/docs/reference_counts_spec.rb`)
- [`SKILL_EXECUTORS.md`](./SKILL_EXECUTORS.md) — the agent → skill binding map
- [`INGRESS_TLS_GUIDE.md`](./INGRESS_TLS_GUIDE.md) — the VIP → port map → ACME → Traefik expose lifecycle from the operator UI
- [`CLAUDE.md`](../CLAUDE.md) — index of all extension agents, including this one
- `docs/reference/system-agent-hierarchy-proposal-2026-09-03.md` (core tree) — the Phase 2 rulings this agent comes from
- `server/spec/db/seeds/system_ingress_manager_agent_seed_spec.rb` — the seed contract

_Last verified: 2026-09-03_
