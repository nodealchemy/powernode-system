# Fleet Sensors — System Extension Reference

The system extension ships **18 concrete sensors** (plus a `BaseSensor` abstract class) at `extensions/system/server/app/services/system/fleet/sensors/`. Sixteen are registered for the live tick loop via `FleetAutonomyService::SENSORS`; the other two (`PackageDriftSensor`, `StorageAssignmentDriftSensor`) run via separate invocation paths and emit signals into the same pipeline. Each sensor inspects a slice of fleet state on a recurring tick, emits typed `FleetEvent` signals when thresholds trip, and feeds the autonomy `DecisionEngine` which gates remediation actions per intervention policy.

## Architecture (one-paragraph summary)

The Fleet Autonomy reconciler runs every 60s (configurable via `autonomy_config.interval_seconds` on the Fleet Autonomy agent; with the 2026-05-10 7-agent split, CVE / SDWAN / Disk Image / Runtime Manager agents each carry their own `interval_seconds` for their respective scopes). Each tick:

1. The 16 sensors in `FleetAutonomyService::SENSORS` run in series (cheap; per-sensor work is bounded by the data it inspects). `PackageDriftSensor` and `StorageAssignmentDriftSensor` run on the same cadence via their owning services and emit signals into the same pipeline.
2. Each sensor emits zero or more `FleetEvent` signals with `kind`, `severity`, `payload`, `correlation_id`
3. The DecisionEngine maps signals → action categories → intervention policy lookup
4. Policy = `auto_approve` → executor runs immediately
5. Policy = `notify_and_proceed` → executor runs + operator notified
6. Policy = `require_approval` → ApprovalRequest queued; executor blocked until operator clicks Approve

```mermaid
flowchart LR
    subgraph Sensors["18 sensors (16 registered for 60s tick, 2 via separate paths)"]
        S1[instance_status]
        S2[module_drift]
        S3[module_promotion]
        S4[certificate_expiry]
        S5[config_drift]
        S6[instance_state_drift]
        S7[sdwan_reachability]
        S8[sdwan_drift]
        S9[sdwan_bgp_session_health]
        S10[sdwan_vip_reachability]
        S11[sdwan_credential_expiry]
        S12[honeypot_access]
        S13[slo_violation]
        S14[project_slo]
        S15[gitops_drift]
        S16[trading_pressure]
        S17[package_drift]
        S18[storage_assignment_drift]
    end
    subgraph Signals["FleetEvent signal kinds"]
        Sig[instance.* / module.* / cert.* / config.* / gitops.*<br/>sdwan.* / honeypot.* / slo.* / project.* / storage.* / fleet.trading_*]
    end
    subgraph Executors["Skill executors (representative — see SKILL_EXECUTORS.md for all 40)"]
        E1[drift_remediate]
        E2[cve_response / cve_remediation_orchestration]
        E3[rolling_module_upgrade]
        E4[sdwan_peer_remediate]
        E5[sdwan_vip_failover]
        E6[sdwan_bgp_session_remediate]
        E7[attribute_failure]
        E8[package_module_refresh]
        E9[architecture_create / update / delete / propose]
    end
    Sensors --> Signals
    Signals --> DE[DecisionEngine]
    DE --> FA[FleetAutonomyService<br/>gate_action!]
    FA --> Executors
```

## Sensor Reference

### `instance_status_sensor` — Heartbeat liveness

**Source:** `instance_status_sensor.rb`
**Watches:** `System::NodeInstance.last_heartbeat_at`
**Threshold:** Configurable per-template; default 5 minutes silent → `instance_silent` signal
**Signals:** `instance.silent`, `instance.recovered`
**Recommended remediation:** `attribute_failure` (skill) for diagnostics, then operator-initiated reprovision.

### `module_drift_sensor` — Module config drift

**Source:** `module_drift_sensor.rb`
**Watches:** `NodeInstance.running_module_digests` vs assigned module digests
**Threshold:** Any digest mismatch → `module_drift` signal
**Signals:** `module.drift_detected`, `module.drift_resolved`
**Recommended remediation:** `drift_remediate` skill (Fleet Autonomy auto-runs with `notify_and_proceed`).

### `module_promotion_sensor` — Promotion-ready modules

**Source:** `module_promotion_sensor.rb`
**Watches:** `NodeModuleVersion.lifecycle_state` transitions (staging → blessed)
**Threshold:** Module spends >24h in staging without operator promotion → `module_promotion_pending` signal
**Signals:** `module.promotion_ready`, `module.promotion_stalled`
**Recommended remediation:** None automated — operator promotes via UI or `system_promote_module_version` MCP action.

### `certificate_expiry_sensor` — TLS cert expiration

**Source:** `certificate_expiry_sensor.rb`
**Watches:** `NodeCertificate.not_after` (mTLS instance certs from `InternalCaService`)
**Threshold:** Cert expires within 14 days → `cert_expiring` signal; expired → `cert_expired` signal
**Signals:** `cert.expiring`, `cert.expired`, `cert.rotated`
**Recommended remediation:** Auto-rotate via `system.cert_rotate` action (Fleet Autonomy `auto_approve` policy). 90-day default lifetime.

### `config_drift_sensor` — On-node config drift

**Source:** `config_drift_sensor.rb`
**Watches:** Agent-reported config hash vs platform-computed config hash
**Threshold:** Hash mismatch → `config_drift` signal
**Signals:** `config.drift_detected`, `config.drift_resolved`
**Recommended remediation:** `drift_remediate` skill (same as module drift).

### `sdwan_reachability_sensor` — Hub reachability

**Source:** `sdwan_reachability_sensor.rb`
**Watches:** `Sdwan::Peer.last_handshake_at` for hub peers
**Threshold:** No handshake in 5 minutes from hub → `sdwan.hub_unreachable` signal
**Signals:** `sdwan.hub_unreachable`, `sdwan.hub_recovered`
**Recommended remediation:** `sdwan_failover` skill (planning-only in v1; operator manually flips `publicly_reachable`).

### `sdwan_drift_sensor` — Topology drift

**Source:** `sdwan_drift_sensor.rb`
**Watches:** Agent-reported wg interface state vs platform desired config
**Threshold:** Interface missing or wrong AllowedIPs → `sdwan.peer_drift` signal
**Signals:** `sdwan.peer_drift_detected`, `sdwan.peer_drift_resolved`
**Recommended remediation:** `sdwan_peer_remediate` skill — rotate keys + force tunnel re-establish.

### `sdwan_bgp_session_health_sensor` — iBGP session health

**Source:** `sdwan_bgp_session_health_sensor.rb`
**Watches:** `Sdwan::BgpSession.state` (Idle/Connect/Active/OpenSent/OpenConfirm/Established)
**Threshold:** Session non-Established for >10 minutes → `sdwan.bgp_unhealthy` signal
**Signals:** `sdwan.bgp_unhealthy`, `sdwan.bgp_recovered`
**Recommended remediation:** `sdwan_bgp_session_remediate` skill (planning-only; operator runs `vtysh` recommendation).

### `sdwan_vip_reachability_sensor` — VIP holder health

**Source:** `sdwan_vip_reachability_sensor.rb`
**Watches:** `Sdwan::VirtualIp.holder_peer_ids` against peer handshake health
**Threshold:** Single-holder VIP's holder is silent → `sdwan.vip_holder_silent` signal
**Signals:** `sdwan.vip_holder_silent`, `sdwan.vip_holder_recovered`
**Recommended remediation:** `sdwan_vip_failover` skill — promotes the next failover candidate.

### `honeypot_access_sensor` — Canary module access

**Source:** `honeypot_access_sensor.rb`
**Watches:** `CanaryModuleService` access logs on canary modules placed in the catalog
**Threshold:** Any access attempt → `honeypot.access` signal (high severity)
**Signals:** `honeypot.access_attempted`, `honeypot.access_blocked`
**Recommended remediation:** None automated — escalates to operator + governance pipeline.

### `slo_violation_sensor` — SLO breach detection

**Source:** `slo_violation_sensor.rb`
**Watches:** `Slo::Definition` rolling-window metrics
**Threshold:** SLO breach → `slo.violated` signal
**Signals:** `slo.violated`, `slo.recovered`
**Recommended remediation:** None automated — surfaces in operator dashboard for manual investigation.

### `trading_pressure_sensor` — Cross-domain coordination

**Source:** `trading_pressure_sensor.rb` (class `TradingPressureSensor`)
**Watches:** Stigmergic pressure signals emitted by sibling extensions on the platform-wide signal bus
**Threshold:** Trading-aggregate pressure ≥1.0 → fleet defers non-critical actions
**Signals:** `fleet.trading_pressure_high`, `fleet.trading_pressure_normal`
**Recommended remediation:** Internal — no executor; the `TradingAwareThrottle` consults this signal to defer Fleet Autonomy actions when trading is under load.
**Naming:** The sensor + throttle consume trading-domain signals specifically. A broader cross-domain refactor (renaming to `ExternalPressureSensor` / `ExternalAwareThrottle` and accepting any sibling extension's pressure feed) is contemplated but not in scope today.

### `instance_state_drift_sensor` — DB↔provider truth divergence

**Source:** `instance_state_drift_sensor.rb`
**Watches:** `NodeInstance` rows whose model status disagrees with provider truth (e.g., DB says `running`, provider says `stopped`).
**Threshold:** Any mismatch outside the in-flight task window → `system.instance_state_drift` signal
**Signals:** `system.instance_state_drift`
**Recommended remediation:** Reconcile — operator-acknowledged correction or `notify_and_proceed` reassertion.

### `gitops_drift_sensor` — Fleet.yaml vs effective fleet divergence

**Source:** `gitops_drift_sensor.rb` (Phase 6c GitOps reconciler integration)
**Watches:** `fleet.yaml`-declared state vs effective fleet (assignments / templates / instances).
**Threshold:** Diff present → `gitops.drift_detected` signal with the proposal payload
**Signals:** `gitops.drift_detected`, `gitops.drift_resolved`
**Recommended remediation:** `Gitops::ApplyService` proposes a reconcile change via `Ai::AgentProposal` (operator approval required for apply).

### `package_drift_sensor` — Package repository freshness

**Source:** `package_drift_sensor.rb`
**Watches:** PackageRepository freshness windows + drift between manifests and registered NodeModules.
**Threshold:** Stale repository sync OR manifest divergence → `system.package_drift_pressure` signal
**Signals:** `system.package_drift_pressure`
**Recommended remediation:** `package_repository_sync` or `package_module_refresh` (Fleet Autonomy `auto_approve` for sync, `notify_and_proceed` for refresh).

### `project_slo_sensor` — Project-scoped SLO monitoring

**Source:** `project_slo_sensor.rb`
**Watches:** Project-scoped rolling-window metrics (latency, error rate, cost guardrail).
**Threshold:** Per-project SLO breach OR cost guardrail trip → typed signal (`project.slo_violation`, `project.drift`, `project.cost_breach`).
**Signals:** `project.slo_violation`, `project.drift`, `project.cost_breach`
**Recommended remediation:** None automated — feeds the project dashboard for operator review.

### `sdwan_credential_expiry_sensor` — SDWAN material expiry watch

**Source:** `sdwan_credential_expiry_sensor.rb`
**Watches:** WireGuard pre-shared keys, IPSec material, peer credentials with TTL ≤ 5 minutes / 15 minutes.
**Threshold:** Per-key advisory/urgent windows → `sdwan.credential_expiring` / `sdwan.credential_expired` signals
**Signals:** `sdwan.credential_expiring`, `sdwan.credential_expired`, `sdwan.credential_rotated`
**Recommended remediation:** `sdwan_key_rotate` (SDWAN Manager `auto_approve`).

### `storage_assignment_drift_sensor` — Storage assignment freshness

**Source:** `storage_assignment_drift_sensor.rb`
**Watches:** Volume / NFS export assignment freshness; 5-minute stale window.
**Threshold:** Stale assignment data → `system.storage_assignment_drift` signal
**Signals:** `system.storage_assignment_drift`
**Recommended remediation:** `attach_storage` / `detach_storage` (operator-approved).

## Decision Engine Flow

```mermaid
flowchart TD
    Tick[Sensor tick 60s] --> Emit[Emit FleetEvent]
    Emit --> Eval[DecisionEngine.evaluate event]
    Eval --> Lookup{Lookup<br/>InterventionPolicy<br/>action_category}

    Lookup -->|auto_approve| AutoExec[Execute immediately<br/>e.g. cert_rotate]
    Lookup -->|notify_and_proceed| NotifyExec[Execute + push notification<br/>e.g. drift_remediate]
    Lookup -->|require_approval| Queue[Queue ApprovalRequest<br/>e.g. cve_remediate]
    Lookup -->|blocked| Drop[Drop — refuse to execute]

    Queue --> OpApprove{Operator<br/>approves?}
    OpApprove -->|yes| Exec2[Execute]
    OpApprove -->|no / timeout| Reject[Rejected]

    AutoExec --> Audit[Audit + FleetEvent + ActionCable broadcast]
    NotifyExec --> Audit
    Exec2 --> Audit
    Drop --> Audit
    Reject --> Audit
```

Action executors live at:

- `extensions/system/server/app/services/system/ai/skills/*_executor.rb`

## Configuring Sensor Thresholds

Sensors read thresholds from `Fleet::SensorConfig` records (account-scoped). Operator-tunable via:

```javascript
// ⚠️ Sensor config MCP actions are aspirational — edit Fleet::SensorConfig via Rails console or REST today
// platform.system_get_sensor_config({ sensor: "instance_status" })      // aspirational
// platform.system_update_sensor_config({                                // aspirational
//   sensor: "instance_status",
//   silent_threshold_minutes: 10  // default 5
// })
```

Until those MCP wrappers ship, configure via Rails console:

```ruby
Fleet::SensorConfig.upsert_for(account: Account.find("<id>"), sensor: "instance_status",
  config: { silent_threshold_minutes: 10 })
```

If no `Fleet::SensorConfig` exists for an account, sensor defaults from constants in each sensor class apply.

## Adding a New Sensor

1. Create `extensions/system/server/app/services/system/fleet/sensors/<name>_sensor.rb` extending `Fleet::Sensors::BaseSensor`.
2. Implement `tick(account:)` returning an array of `FleetEvent` rows (or empty).
3. Register the sensor in `Fleet::Reconciler` so it runs on each autonomy tick.
4. Add an intervention policy entry in `fleet_autonomy_agent.rb` for the action category your sensor's recommendation maps to.
5. Add a corresponding skill executor (if remediation is automatable) — see `SKILL_EXECUTORS.md`.

## Intervention Policy Reference

Seven AI agents seed intervention policies (action_category → policy mapping) since the 2026-05-10 domain split. Sourced from:

- `db/seeds/fleet_autonomy_agent.rb` — **18 policies** (non-CVE / non-SDWAN / non-disk-image fleet ops)
- `db/seeds/system_runtime_manager_agent.rb` — **7 policies** (Phase 1 Docker + Phase 2 K3s runtime; the prior `system.runtime_docker_tls_rotate` was removed 2026-05-19 — no executor existed)
- `db/seeds/system_cve_responder_agent.rb` — **5 policies** (CVE feed → exposure → remediation; CVE policies historically lived on Fleet Autonomy)
- `db/seeds/system_sdwan_manager_agent.rb` — **31 policies** (SDWAN networks / peers / VIPs / firewall / route policies / federation — moved off Fleet Autonomy 2026-05-10)
- `db/seeds/system_disk_image_manager_agent.rb` — **6 policies** (disk image CI publication lifecycle)
- `db/seeds/system_concierge_agent.rb` — Concierge is a chat agent; intervention via `request_confirmation` skill rather than action-category policies
- `db/seeds/system_topology_designer_agent.rb` — Topology Designer is a specialist invoked by Concierge via `execute_agent`; intervention is on the parent agent's queue

**= 68 action-category policies across the seven system-extension agents.**

**Policy semantics:**

| Policy | Behavior |
|---|---|
| `auto_approve` | Skill executes immediately on the next reconciler tick. Reversible / routine work only. |
| `notify_and_proceed` | Skill executes + operator notification fires. Operator opted in by upstream config. |
| `require_approval` | `ApprovalRequest` queued; skill blocked until operator clicks Approve. Sensitive / destructive work. |
| `blocked` | Action is disabled entirely. Reserved for incident response. |

All policies decay to the agent's `trust_tier_minimum: monitored` condition — agents below trust threshold are auto-blocked regardless of policy.

### Fleet Autonomy agent (18 policies)

Source: `db/seeds/fleet_autonomy_agent.rb`. Approval chain: `Fleet Autonomy Actions` (4-hour timeout, `*` approver, sequential). **Note: as of 2026-05-10, CVE policies moved to `system_cve_responder_agent.rb`, SDWAN policies to `system_sdwan_manager_agent.rb`, and Disk Image policies to `system_disk_image_manager_agent.rb` — they no longer live here.**

| Action category | Default policy | Why |
|---|---|---|
| `system.cert_rotate` | `auto_approve` | Routine + reversible (90-day mTLS rotation) |
| `system.module_assign` | `notify_and_proceed` | Operator already opted-in by configuring template |
| `system.instance_reboot` | `notify_and_proceed` | Reversible — instance returns within ~60 s |
| `system.instance_reprovision` | `require_approval` | Destructive — wipes ephemeral state |
| `system.instance_terminate` | `require_approval` | Destructive — releases provider VM, cascade-FK deletes managed rows |
| `system.cert_revoke` | `require_approval` | Cuts active mTLS session |
| `system.module_promote_to_live` | `require_approval` | Promotes module across the fleet |
| `system.fleet_rolling_upgrade` | `require_approval` | Touches many instances; `rolling_module_upgrade` skill plans batches |
| `system.region_expansion` | `require_approval` | Cost-bearing |
| `system.capacity_resize` | `require_approval` | Cost-bearing; `capacity_recommend` skill emits the proposal |
| `system.observation` | `auto_approve` | Pure observation — no remediation; collects events for dashboards |
| `system.package_repository.sync` | `auto_approve` | Routine PackageRepository refresh |
| `system.package_module.create` | `notify_and_proceed` | Materialises a NodeModule from PackageRepository |
| `system.package_module.refresh` | `notify_and_proceed` | Re-resolves dependencies / re-validates manifest |
| `system.architecture.propose` | `notify_and_proceed` | `suggest_architectures_for_fleet` skill emits proposals |
| `system.architecture.create` | `require_approval` | Catalog change — affects future provisioning |
| `system.architecture.update` | `require_approval` | Catalog change |
| `system.architecture.delete` | `require_approval` | Catalog change |

### CVE Responder agent (5 policies)

Source: `db/seeds/system_cve_responder_agent.rb`. Approval chain: `CVE Response Actions` (8-hour timeout — security responses span business days).

| Action category | Default policy | Why |
|---|---|---|
| `system.cve_remediate` | `require_approval` | Composes `cve_response` + `rolling_module_upgrade`; touches fleet |
| `system.cve_sbom_ingest` | `auto_approve` | Routine SBOM refresh from NVD feed |
| `system.cve_exposure_scan` | `auto_approve` | Read-only scan for exposed modules |
| `system.cve_auto_remediate` | `require_approval` | Auto-remediation candidate (`CriticalUpgradeAvailableSensor`) |
| `system.module_critical_upgrade_ready` | `notify_and_proceed` | Patch already in catalog — fly it (gated by operator notify) |

### SDWAN Manager agent (31 policies)

Source: `db/seeds/system_sdwan_manager_agent.rb`. Approval chain: `SDWAN Manager Actions` (4-hour timeout). Mix of network/peer/firewall/VIP/route-policy/port-mapping/access-grant/user-device/federation categories. Examples: `system.sdwan_peer_remediate` (notify), `system.sdwan_key_rotate` (auto), `system.sdwan_failover` (require), `system.sdwan_vip_failover` (require), `system.sdwan_route_policy_audit` (auto), `system.sdwan_user_device_revoke` (require), `system.sdwan_federation_accept` (require). See [`SDWAN_MANAGER_AGENT.md`](./SDWAN_MANAGER_AGENT.md) for the full table.

### Disk Image Manager agent (6 policies)

Source: `db/seeds/system_disk_image_manager_agent.rb`. Approval chain: `Disk Image Manager Actions` (12-hour timeout — image promotions span release windows). See [`DISK_IMAGE_MANAGER_AGENT.md`](./DISK_IMAGE_MANAGER_AGENT.md) for the full table. Categories include `system.disk_image_publication_promote`, `system.disk_image_publication_rollback`, `system.disk_image_webhook_trigger`, `system.disk_image_retention_update`. **Note (2026-05-19 audit):** two policies (`system.disk_image_webhook_revoke`, `system.disk_image_webhook_rotate_secret`) are seeded but their executors are pending — see [B2 in the audit report](./history/audits/2026-05-19-doc-accuracy-audit.md#6-suspected-code-bugs).

### Runtime Manager agent (8 policies)

Source: `db/seeds/system_runtime_manager_agent.rb`. Approval chain: `Runtime Manager Actions` (4-hour timeout, `*` approver, sequential, separate from Fleet Autonomy chain).

| Action category | Default policy | Why |
|---|---|---|
| `system.runtime_docker_provision` | `notify_and_proceed` | Operator opted in by assigning `docker-engine` module; provisioning is the obvious follow-through |
| `system.runtime_docker_decommission` | `require_approval` | Destructive — destroys managed `Devops::DockerHost` row + Vault TLS material |
| `system.runtime_docker_tls_rotate` | `auto_approve` | Aligns with `system.cert_rotate` hands-off posture |
| `system.runtime_k8s_cluster_bootstrap` | `notify_and_proceed` | Operator opted in by assigning `k3s-server` module |
| `system.runtime_k8s_cluster_decommission` | `require_approval` | Destructive — cascade-deletes member node rows |
| `system.runtime_k8s_node_join` | `notify_and_proceed` | Operator opted in by assigning `k3s-agent` module |
| `system.runtime_k8s_node_drain` | `require_approval` | Affects running pods |
| `system.runtime_k8s_runtime_upgrade` | `require_approval` | Affects workloads |

### Override path

Operators can override any policy per-account via the AI Agents UI or by editing `Ai::InterventionPolicy` directly:

```javascript
// Tighten a default-auto policy
platform.update_intervention_policy({
  agent_id: "<fleet-autonomy-agent-id>",
  action_category: "system.cert_rotate",
  policy: "require_approval"
})
```

Policy changes take effect on the next reconciler tick (≤60 s).

### Consent budget (per-module ceiling)

In addition to per-policy gates, operators can set a per-module **consent budget** capping the daily count of autonomous decisions touching that module. Once exhausted, all autonomous actions on that module are forced to `require_approval` regardless of policy. See `app/services/system/fleet/consent_budget_service.rb`.

## Related Docs

- `extensions/system/docs/SKILL_EXECUTORS.md` — remediation actions invoked by sensor signals
- `extensions/system/docs/ARCHITECTURE.md` — autonomy + decision engine subsystem
- `extensions/system/docs/CONTAINER_RUNTIMES.md` — runtime-specific monitoring (Runtime Manager agent has its own policies)
- `extensions/system/docs/runbooks/cve-response.md` — operator runbook using `cve_remediate` policy chain
- `extensions/system/docs/runbooks/sdwan-network-setup.md` — operator runbook covering SDWAN policies
