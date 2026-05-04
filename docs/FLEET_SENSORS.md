# Fleet Sensors — System Extension Reference

The system extension ships 13 sensors at `extensions/system/server/app/services/system/fleet/sensors/`. Each sensor inspects a slice of fleet state on a recurring tick, emits typed `FleetEvent` signals when thresholds trip, and feeds the autonomy `DecisionEngine` which gates remediation actions per intervention policy.

## Architecture (one-paragraph summary)

The Fleet Autonomy reconciler runs every 60s (configurable via `autonomy_config.interval_seconds` on the Fleet Autonomy agent). Each tick:

1. All 13 sensors run in series (cheap; per-sensor work is bounded by the data it inspects)
2. Each sensor emits zero or more `FleetEvent` signals with `kind`, `severity`, `payload`, `correlation_id`
3. The DecisionEngine maps signals → action categories → intervention policy lookup
4. Policy = `auto_approve` → executor runs immediately
5. Policy = `notify_and_proceed` → executor runs + operator notified
6. Policy = `require_approval` → ApprovalRequest queued; executor blocked until operator clicks Approve

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

**Source:** `trading_pressure_sensor.rb`
**Watches:** Trading extension's `trading.*` stigmergic signals (per memory `cross_domain_coordination`)
**Threshold:** Trading aggregate pressure ≥1.0 → fleet defers non-critical actions
**Signals:** `fleet.trading_pressure_high`, `fleet.trading_pressure_normal`
**Recommended remediation:** Internal — no executor; the `TradingAwareThrottle` consults this signal to defer Fleet Autonomy actions when trading is hot.

## Decision Engine Flow

```
Sensor tick (60s) → emit FleetEvent → DecisionEngine.evaluate(event)
   │
   ├─ Lookup InterventionPolicy(action_category, agent: Fleet Autonomy)
   │
   ├─ auto_approve     → execute immediately (e.g. cert_rotate)
   ├─ notify_and_proceed → execute + push notification (e.g. drift_remediate)
   └─ require_approval → ApprovalRequest queued (e.g. cve_remediate)

Action executors live at:
  extensions/system/server/app/services/system/ai/skills/*_executor.rb
  extensions/system/server/app/services/system/fleet/actions/*_action.rb (write actions)
```

## Configuring Sensor Thresholds

Sensors read thresholds from `Fleet::SensorConfig` records (account-scoped). Operator-tunable via:

```javascript
// Get current thresholds for a sensor
platform.system_get_sensor_config({ sensor: "instance_status" })

// Override for an account
platform.system_update_sensor_config({
  sensor: "instance_status",
  silent_threshold_minutes: 10  // default 5
})
```

If no `Fleet::SensorConfig` exists for an account, sensor defaults from constants in each sensor class apply.

## Adding a New Sensor

1. Create `extensions/system/server/app/services/system/fleet/sensors/<name>_sensor.rb` extending `Fleet::Sensors::BaseSensor`.
2. Implement `tick(account:)` returning an array of `FleetEvent` rows (or empty).
3. Register the sensor in `Fleet::Reconciler` so it runs on each autonomy tick.
4. Add an intervention policy entry in `fleet_autonomy_agent.rb` for the action category your sensor's recommendation maps to.
5. Add a corresponding skill executor (if remediation is automatable) — see `SKILL_EXECUTORS.md`.

## Related Docs

- `extensions/system/docs/SKILL_EXECUTORS.md` — remediation actions invoked by sensor signals
- `extensions/system/docs/ARCHITECTURE.md` — autonomy + decision engine subsystem
- `extensions/system/docs/CONTAINER_RUNTIMES.md` — runtime-specific monitoring (Runtime Manager agent has its own policies)
