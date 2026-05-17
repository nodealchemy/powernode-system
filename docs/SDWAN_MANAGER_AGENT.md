# SDWAN Manager Agent — Operator Guide

The **SDWAN Manager** is one of the autonomous agents seeded into every Powernode account. It owns SDWAN reconciliation: peer health, topology compilation, VIP failover, federation peering, and BGP session triage. Carved out of Fleet Autonomy on 2026-05-10 so SDWAN ops have an independent intervention queue — operators can pause SDWAN during a network maintenance window without halting fleet ops.

Source of truth for this guide: `extensions/system/server/db/seeds/system_sdwan_manager_agent.rb`.

---

## Charter

The SDWAN Manager is a **monitor** agent (no chat surface; it executes autonomous reconciliations and operator-initiated SDWAN actions). It ticks every **60 seconds** under autonomy scope `sdwan`.

What it owns:
- **Peer health** — drift, key rotation, BGP session liveness
- **Topology compilation** — recompile and apply route policies + iBGP advertisements when networks change
- **VIP failover** — promote a healthy holder when an anycast VIP loses its primary
- **Federation peering** — propose/accept/revoke cross-platform peers
- **Operator-initiated mutations** — every CRUD against networks, peers, firewall rules, VIPs, route policies, port mappings, access grants, user devices flows through this agent's approval chain

What it does **not** own:
- Container runtime provisioning (→ Runtime Manager)
- CVE response (→ CVE Responder)
- Cross-cutting topology composition like OVN logical networks + IPFIX collectors (→ System Topology Designer; the SDWAN Manager calls these compose skills indirectly via federation)
- Disk image CI publication (→ Disk Image Manager)

---

## Intervention Policies

The agent ships with **28 intervention policies** (count current as of 2026-05-10). Each policy maps an `action_category` to one of four policy types:

| Policy type | Behavior |
|---|---|
| `auto_approve` | Execute immediately. Telemetry only — no operator interaction. |
| `notify_and_proceed` | Execute immediately, but emit a notification so operators see what was done. |
| `require_approval` | Block on operator approval via the approval chain. 4-hour timeout (see below) — past that, **reject** by default. |
| `blocked` | Refuse to execute. (Not used in the default seed; available for emergency lockdowns.) |

### Policy table

#### Autonomous reconciliations (sensor-triggered)
| Action | Policy | Why |
|---|---|---|
| `system.sdwan_peer_remediate` | `notify_and_proceed` | Recovering a peer is generally safe (key rotation, re-enrollment) |
| `system.sdwan_key_rotate` | `auto_approve` | Routine credential rotation |
| `system.sdwan_failover` | `require_approval` | Hub failover affects traffic flow across the network |
| `system.sdwan_user_device_revoke` | `require_approval` | Cuts a user's connectivity |
| `system.sdwan_bgp_session_remediate` | `notify_and_proceed` | Re-establishing iBGP is safe; refusal-to-restart loops would be noisy |
| `system.sdwan_vip_failover` | `require_approval` | Manual failover bypasses the automated VIP promotion logic |
| `system.sdwan_route_policy_audit` | `auto_approve` | Read-only audit |

#### Network CRUD (operator-initiated)
| Action | Policy |
|---|---|
| `sdwan.network_create` | `notify_and_proceed` |
| `sdwan.network_update` | `notify_and_proceed` |
| `sdwan.network_delete` | `require_approval` |

#### Peer CRUD
| Action | Policy |
|---|---|
| `sdwan.peer_create` | `notify_and_proceed` |
| `sdwan.peer_update` | `notify_and_proceed` |
| `sdwan.peer_delete` | `require_approval` |

#### Firewall rules
| Action | Policy |
|---|---|
| `sdwan.firewall_rule_create` | `notify_and_proceed` |
| `sdwan.firewall_rule_update` | `notify_and_proceed` |
| `sdwan.firewall_rule_delete` | `require_approval` |

#### Virtual IPs
| Action | Policy |
|---|---|
| `sdwan.virtual_ip_create` | `notify_and_proceed` |
| `sdwan.virtual_ip_update` | `notify_and_proceed` |
| `sdwan.virtual_ip_delete` | `require_approval` |

#### Route policies
| Action | Policy |
|---|---|
| `sdwan.route_policy_create` | `notify_and_proceed` |
| `sdwan.route_policy_update` | `notify_and_proceed` |
| `sdwan.route_policy_delete` | `require_approval` |

#### Port mappings (DNAT)
| Action | Policy |
|---|---|
| `sdwan.port_mapping_create` | `notify_and_proceed` |
| `sdwan.port_mapping_update` | `notify_and_proceed` |
| `sdwan.port_mapping_delete` | `notify_and_proceed` |

#### Access grants
| Action | Policy |
|---|---|
| `sdwan.access_grant_create` | `notify_and_proceed` |
| `sdwan.access_grant_revoke` | `require_approval` |

#### User devices
| Action | Policy |
|---|---|
| `sdwan.user_device_create` | `notify_and_proceed` |

#### Federation peering
| Action | Policy |
|---|---|
| `sdwan.federation_peer_propose` | `require_approval` |
| `sdwan.federation_peer_accept` | `require_approval` |
| `sdwan.federation_peer_revoke` | `require_approval` |

Federation actions are all `require_approval` because cross-platform peering crosses an administrative trust boundary.

### Tuning a policy

To change a policy at runtime (e.g., relax `notify_and_proceed` to `auto_approve` for a low-risk action in your environment), update the `Ai::InterventionPolicy` row directly:

```ruby
# rails console
agent = Ai::Agent.find_by(name: "SDWAN Manager")
Ai::InterventionPolicy.find_by(
  ai_agent_id: agent.id, action_category: "sdwan.port_mapping_create"
).update!(policy: "auto_approve")
```

The change takes effect on the next tick (within 60s). To make the change durable across re-seeds, edit `system_sdwan_manager_agent.rb` and re-run `cd server && rails db:seed`.

---

## Approval Chain

Approval-required actions flow through the **SDWAN Manager Actions** approval chain:

- **Trigger type:** `autonomy_action`
- **Sequential:** yes (one step today)
- **Timeout:** **4 hours**, then auto-reject
- **Approvers:** any user with permission `system.infra_tasks.control`
- **Required approvals per step:** 1

To add additional approvers (e.g., a security review for `federation_peer_*` actions), edit the `steps` array in the seed file and re-seed.

---

## Skill Bindings

SDWAN Manager invokes its work through bound skills (the LLM sees these in its prompt-context skill catalog and calls them):

- `system-sdwan-failover` — hub failover planner
- `system-sdwan-peer-remediate` — peer key rotation + re-enrollment
- `system-sdwan-bgp-session-remediate` — iBGP session restart + reconfiguration
- `system-sdwan-vip-failover` — VIP holder promotion

Cross-cutting composition skills (`system-sdwan-host-bridge-compose`, `system-sdwan-ovn-compose-topology`, `system-sdwan-ipfix-collector-compose`, `system-sdwan-compose-full-topology`, `system-sdwan-ovn-apply-acl`) are bound to **System Topology Designer**, not to SDWAN Manager. Use the topology designer (invoked via Concierge) when you need an end-to-end topology composition; SDWAN Manager handles steady-state reconciliation of the resulting topology.

For the full skill catalog with descriptor I/O, see [SKILL_EXECUTOR_CATALOG.md](./SKILL_EXECUTOR_CATALOG.md).

---

## Sensor → Action Map

SDWAN Manager actions are triggered by Fleet sensors emitting `system.sdwan_*` signals. The standard mapping (see [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) for sensor descriptors):

| Sensor → Signal | Triggers action | Policy default |
|---|---|---|
| `sdwan.peer_reachability` → drift | `system.sdwan_peer_remediate` | `notify_and_proceed` |
| `sdwan.bgp_session` → down | `system.sdwan_bgp_session_remediate` | `notify_and_proceed` |
| `sdwan.vip_reachability` → primary unhealthy | `system.sdwan_vip_failover` | `require_approval` |
| `sdwan.hub_reachability` → hub unreachable | `system.sdwan_failover` | `require_approval` |
| `sdwan.route_policy_drift` → policy hash mismatch | `system.sdwan_route_policy_audit` | `auto_approve` |
| Time-based (key TTL) | `system.sdwan_key_rotate` | `auto_approve` |

---

## Pause / Resume — Maintenance Window Runbook

When you need to pause SDWAN reconciliation (e.g., a maintenance window where you're manually changing BGP config and don't want the agent fighting you):

### Pause
```ruby
# rails console
agent = Ai::Agent.find_by(name: "SDWAN Manager")
agent.update!(status: "paused")
```

The agent will skip its next tick. Existing approvals already in the queue are unaffected (they stay pending; operators can still approve or reject them).

### Verify paused
```bash
curl -s -H "Authorization: Bearer $JWT" http://localhost:3000/api/v1/ai/agents \
  | jq '.data[] | select(.name=="SDWAN Manager") | {name, status, last_tick_at}'
```

### Resume
```ruby
agent.update!(status: "active")
```

Resumption takes effect on the next tick (within 60s of the next scheduled run).

### Emergency halt (all autonomy)

For unscoped emergencies (e.g., suspected agent misbehavior across the platform), use the kill switch instead — it halts ALL autonomous agents, not just SDWAN Manager:

```
platform.emergency_halt
```

To resume:
```
platform.emergency_resume
```

---

## Observability

Every decision SDWAN Manager makes lands in three places:

1. **FleetEvent log** — `System::FleetEvent` rows with `source: "sdwan_manager"`, queryable via `platform.recent_events` or the Fleet Dashboard
2. **ActionCable broadcast** — live UI updates on `SystemFleetChannel` (subscribers see decisions stream into the dashboard)
3. **Approval queue** — `Ai::ApprovalRequest` rows for `require_approval` actions, visible at `/ai/autonomy/approvals` in the operator UI

For audit-grade retention: critical events retain 365 days; routine reconciliations retain 90 days (per FleetEvent retention policy).

---

## Related Documents

- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) — the sensors that emit `sdwan.*` signals
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) §5 — SDWAN subsystem reference (model + service layer)
- [`runbooks/sdwan-network-setup.md`](./runbooks/sdwan-network-setup.md) — end-to-end SDWAN provisioning runbook
- [`SKILL_EXECUTOR_CATALOG.md`](./SKILL_EXECUTOR_CATALOG.md) — full skill executor catalog (auto-generated)
- [`CLAUDE.md`](../CLAUDE.md) — index of all extension agents, including this one
