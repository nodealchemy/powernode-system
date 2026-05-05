# Example 08 — Honeypot canary detection + alert

End-to-end walkthrough: deploy a canary module to a NodeInstance, simulate unauthorized access, observe `honeypot_access_sensor` fire, escalate to operator. Companion seed: `db/seeds/example_honeypot.rb` (Phase 3).

**Goal:** validate the honeypot canary defense pattern — detect lateral movement or credential abuse via decoy assets that should never be touched.

**Audience:** security operators, threat hunters, SOC analysts.

**Prerequisites:**
- A NodeInstance you can SSH to (via SDWAN) for the simulation step
- Operator with `system.honeypot.read` permissions

## Concept

A **honeypot canary** is a fake asset placed on a NodeInstance — a file, a service, a credential — that no legitimate process should ever access. When it IS accessed, the agent emits `honeypot.access_attempted` to the platform's `FleetEvent` log. The `honeypot_access_sensor` picks this up on its next tick (60 s) and triggers operator escalation.

Common canary types:
- **File canaries** — files in `/etc/`, `/var/lib/`, `~/` with provocative names (e.g., `/etc/cluster-credentials.yaml`); accessed via `inotifywait` watcher
- **Service canaries** — fake daemons listening on tempting ports (port 21 / FTP, port 23 / Telnet) that log connection attempts
- **Credential canaries** — fake API keys / SSH keys / DB creds inserted into `/etc/`, configured to alert on use (e.g., a fake AWS key that triggers a CloudTrail alert)

## Step 1 — Deploy the canary module

The system extension ships a `honeypot-canary` module that includes the inotify watcher and event-emitter daemon:

```javascript
// Assign the canary module to a Template (or directly to a Node via metadata)
platform.system_assign_module_to_template({
  template_id: "<honeypot-template>",
  module_name: "honeypot-canary",
  config: {
    canary_files: [
      "/etc/cluster-admin-credentials.yaml",
      "/var/lib/secret-keys.json"
    ],
    canary_ports: [21, 23],
    alert_severity: "high"
  }
})
```

After ~60 s, the assigned NodeInstance has:
- `/etc/cluster-admin-credentials.yaml` (a fake YAML file with fake creds)
- `/var/lib/secret-keys.json`
- A daemon listening on ports 21 + 23 that logs connection attempts
- An inotify watcher monitoring the canary files

```javascript
// Mark the canary as "active" via MCP
platform.system_node_mark_canary({ node_id: "<id>", canary_id: "..." })
```

## Step 2 — Simulate unauthorized access

SSH to the NodeInstance (use `system_execute_task` if SSH isn't available):

```bash
# Simulate a file read
cat /etc/cluster-admin-credentials.yaml
# → fake YAML content (looks real to attackers)

# Simulate a port scan
nmap -p 21,23 fd00:abcd:1::42
# → hits the canary daemon
```

## Step 3 — Observe sensor firing

The agent's inotify watcher detects the file read; emits a signal to platform via `worker_api/events`:

```javascript
platform.recent_events({ kind: "honeypot.access_attempted", limit: 10 })
// → events: [{
//      kind: "honeypot.access_attempted",
//      severity: "high",
//      payload: {
//        node_instance_id: "...",
//        canary_path: "/etc/cluster-admin-credentials.yaml",
//        accessing_process: "bash",
//        accessing_user: "root",
//        accessed_at: "2026-05-04T13:42:01Z"
//      },
//      correlation_id: "..."
//    }]
```

Within 60 s, `honeypot_access_sensor` runs in the autonomy reconciler. It:
1. Sees the `honeypot.access_attempted` event
2. Generates an escalation `FleetEvent` (`severity: high`)
3. Per intervention policy (no auto-action; manual escalation), surfaces in operator dashboard

## Step 4 — Operator response

```javascript
// Operator sees alert in /app/system/operations
// Or via MCP:
platform.system_get_governance_dashboard()
// → { alerts: [{
//      kind: "honeypot.access_attempted",
//      severity: "high",
//      affected_resources: ["instance:<id>"],
//      ...
//    }] }
```

Recommended response:
1. **Isolate** — `platform.system_sdwan_create_firewall_rule` to drop traffic to the affected instance pending forensics
2. **Snapshot** — create a libvirt/provider snapshot of the disk for evidence
3. **Investigate** — use `attribute_failure` skill to enumerate recent module / config changes; correlate with `journalctl` on the instance
4. **Decide** — re-image the instance, terminate it, or restore from a known-good state

## Step 5 — Document the response

```javascript
platform.create_learning({
  title: "Honeypot canary triggered on instance X — DRILL or REAL classification",
  category: "discovery",
  content: "...",
  tags: ["honeypot", "incident-response"],
  related_entities: [{ type: "instance", id: "..." }]
})
```

For real incidents (not drills), open an incident ticket per your team's IR runbook.

## Step 6 — Cleanup (drill only)

```javascript
// Unassign the canary module
platform.system_unassign_module_from_template({
  template_id: "<honeypot-template>",
  module_name: "honeypot-canary"
})

// Or terminate the test instance
platform.system_terminate_instance({ id: "<test-instance-id>" })
```

## What to watch

- **False positives** — legitimate processes (backup jobs, security scanners) reading canary paths. Tune `canary_files` to genuinely never-touched paths.
- **Multi-instance correlation** — if multiple instances trigger canaries within minutes, lateral movement is likely; escalate to incident immediately
- **Drill vs real** — always tag drill events explicitly (e.g., learning title prefixed with `DRILL:`); never confuse drill response with real IR
- **Sensor cadence** — `honeypot_access_sensor` runs every 60 s; for sub-minute alerts, push directly via WebSocket or escalate via `send_proactive_notification`

## Related

- [`FLEET_SENSORS.md`](../FLEET_SENSORS.md) — `honeypot_access_sensor` reference
- [`ARCHITECTURE.md`](../ARCHITECTURE.md) §7 — Honeypot canaries subsystem (Track F-7)
- `app/services/system/honeypot/canary_module_service.rb` — backing service
- `app/services/system/fleet/sensors/honeypot_access_sensor.rb` — sensor source
