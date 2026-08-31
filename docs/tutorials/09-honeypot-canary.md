# Tutorial 09 — Honeypot canaries

> Status: active

> **What you'll learn:** Deploy a honeypot canary module that creates decoy
> assets on a NodeInstance, simulate unauthorized access, watch the
> `honeypot_access_sensor` fire, and escalate through the operator
> dashboard.
>
> **Time:** ~20 min
>
> **Builds on:** [Tutorial 01](./01-first-boot.md) — needs a running NodeInstance
> you can SSH to (via SDWAN) for the simulation step.
>
> **Sets you up for:** [Tutorial 10 — GitOps fleet](./10-gitops-fleet.md) —
> declarative management; you can codify "every prod node gets a honeypot
> module" in `fleet.yaml`.

<!-- signal-kind-corrections:start -->
> **Corrected 2026-08-31 (IMP-e491c01f5c01).** This tutorial named a signal
> kind that does not exist, in nine places — including copy-pasteable
> `platform.recent_events` calls. Those calls returned an empty list with
> `success: true`: a successful-looking response, and no indication that the
> kind was never emitted.
>
> | Named here until 2026-08-31 | Actually emitted |
> |---|---|
> | `honeypot.access_attempted` (the stored event) | `system.honeypot_triggered` |
> | `honeypot.access_attempted` (the escalation/alert) | `system.honeypot_access` |
>
> `honeypot.access_attempted` is **NOT IMPLEMENTED** and never was. Note that
> the one fabricated name stood for **two** distinct real kinds — see Step 4.
>
> **Also NOT IMPLEMENTED: the trigger mechanism described below.** The steps
> that follow describe decoy *files* on disk and an inotify watcher inside
> `powernode-agent` that posts on file access. No such support exists:
> `agent/` contains no canary, honeypot, or file-access watcher code. (The
> agent does have a general FleetEvent POST facility —
> `agent/internal/fleetevent/` — and the endpoint accepts an arbitrary `kind`;
> what is missing is anything that would DETECT a canary access and call it.)
> The only in-repo code that emits
> `system.honeypot_triggered` today is
> `System::Honeypot::CanaryModuleService.observe_access!`, called from one
> place: the `after_commit` hook on `System::NodeModuleAssignment` (create).
> So the real trigger is a canary *module being assigned to a node*, not a
> file being read. Steps 1–2 and 4–5 (marking a canary, and reading the
> resulting events) are accurate; the Step 3 simulation is not, and
> `db/seeds/example_honeypot.rb` fabricates the event directly rather than
> exercising a real path.
<!-- signal-kind-corrections:end -->

## What you're building

```mermaid
sequenceDiagram
    actor Op as Operator
    participant Plat as Platform
    participant Agent as powernode-agent
    participant FS as Decoy files +<br/>fake daemons
    participant Atk as Attacker<br/>(or drill operator)
    participant Sensor as honeypot_access_sensor
    participant FE as FleetEvent log

    Op->>Plat: assign honeypot-canary module<br/>config: canary_files + canary_ports
    Plat-->>Agent: heartbeat picks up module
    Agent->>FS: write decoy files,<br/>start fake port daemons,<br/>start inotify watcher
    Op->>Plat: system_module_mark_canary
    Note over FS: idle — should never be accessed

    Atk->>FS: cat /etc/cluster-admin-credentials.yaml
    FS->>Agent: inotify event:<br/>file accessed
    Agent->>Plat: POST /worker_api/events<br/>system.honeypot_triggered
    Plat->>FE: persist FleetEvent
    Sensor->>FE: tick (60s)<br/>finds new event
    Sensor->>Plat: emit escalation event<br/>(severity: high)
    Plat-->>Op: dashboard alert<br/>(governance dashboard)
    Op->>Op: isolate + snapshot + investigate
```

By the end you'll have a working canary-based detection layer and a
documented response procedure.

## Concept refresher

A **honeypot canary** is a fake asset placed on a NodeInstance — a file,
a service, a credential — that no legitimate process should ever access.
When it IS accessed, a `system.honeypot_triggered` FleetEvent is written to the
platform's `FleetEvent` log. The `honeypot_access_sensor` (see
[`FLEET_SENSORS.md`](../FLEET_SENSORS.md)) picks this up on its next tick
(60s) and triggers operator escalation.

Common canary types:

- **File canaries** — files in `/etc/`, `/var/lib/`, `~/` with provocative
  names (e.g., `/etc/cluster-credentials.yaml`); accessed via `inotifywait` watcher
- **Service canaries** — fake daemons on tempting ports (21 / FTP, 23 / Telnet)
  that log connection attempts
- **Credential canaries** — fake API keys / SSH keys / DB creds with
  external alerting (e.g., a fake AWS key wired to CloudTrail)

**Why canaries work:** legitimate workloads never need to read
`/etc/cluster-admin-credentials.yaml`. Anything that does is by
definition unauthorized. Low false-positive rate, high signal-to-noise.

**The trust boundary:** sensor lives in the platform; agent emits the
event from the instance. Tampering with the agent on a compromised
instance can suppress the alert — defense in depth via SDWAN
segmentation + immutable initramfs + fs-verity makes that hard.

## Prerequisites

| Requirement | How |
|---|---|
| A NodeInstance you can SSH to (via SDWAN) | Tutorial 01 + `system_sdwan_create_access_grant` |
| Operator with `system.honeypot.read` permission | Default for admins |
| `honeypot-canary` module in catalog, with a `current: true` version carrying an artifact | Ships in default catalog. A promotion state is **not** a prerequisite — no node-facing surface reads `promotion_state`; the agent is served whatever `NodeModule#current_version_id` points at |

## Step 1 — Assign the canary module

```javascript
platform.system_assign_module_to_template({
  template_id: "<honeypot-template-id>",      // or your existing template
  // The template-assignment verbs take the NodeModule UUID, not its name — system_list_modules returns { id, name }.
  module_id: "<honeypot-canary-module-id>",
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

**Expected outcome:** within ~60s, the assigned NodeInstance has:

- `/etc/cluster-admin-credentials.yaml` — fake YAML with fake creds (looks real)
- `/var/lib/secret-keys.json` — fake key bundle
- A daemon on ports 21 + 23 that logs connection attempts
- An inotify watcher on the canary files

## Step 2 — Mark the canary "active"

```javascript
platform.system_module_mark_canary({
  module_id: "<canary-module-id>"
})
```

**Expected outcome:** governance dashboard tile shows the canary as
actively monitored. Future access events route through the configured
intervention policy (default: notify-and-proceed for `high` severity).

## Step 3 — Simulate unauthorized access (drill)

SSH to the NodeInstance (SSH is the primary path for running commands on an
instance):

```bash
# Simulate a file read
cat /etc/cluster-admin-credentials.yaml
# → fake YAML content

# Simulate a port scan
nmap -p 21,23 fd00:abcd:1::42
# → connects to fake daemon
```

**Expected outcome:** within seconds, the agent's inotify watcher
detects the read and posts to platform.

## Step 4 — Observe sensor firing

```javascript
platform.recent_events({ kind: "system.honeypot_triggered", limit: 10 })
// → events: [{
//      kind: "system.honeypot_triggered",
//      severity: "high",
//      payload: {
//        node_instance_id: "...",
//        canary_path: "/etc/cluster-admin-credentials.yaml",
//        accessing_process: "bash",
//        accessing_user: "root",
//        accessed_at: "2026-05-17T13:42:01Z"
//      },
//      correlation_id: "..."
//    }]
```

Two kinds are involved, and filtering on the wrong one returns an empty
list with `success: true`:

- `system.honeypot_triggered` — written when the canary is touched
  (`System::Honeypot::CanaryModuleService.observe_access!`). This is the
  event you query above.
- `system.honeypot_access` — the ESCALATION signal `honeypot_access_sensor`
  emits after reading the event above. `DecisionEngine::SIGNAL_BINDINGS`
  keys on this one, which is what drives the intervention policy.

Within 60s, `honeypot_access_sensor` runs in the autonomy reconciler.
It:

1. Sees the `system.honeypot_triggered` event
2. Emits a `system.honeypot_access` signal (severity: **critical**) — an
   in-memory `System::Fleet::Signal` consumed by the DecisionEngine, not a
   persisted FleetEvent
3. Per intervention policy, surfaces in operator dashboard

## Step 5 — Operator response

```javascript
platform.governance_dashboard()
// → { open_reports, critical_reports, by_type, by_severity,
//     collusion_indicators, agents_under_investigation }
```

> **NOT IMPLEMENTED — corrected 2026-08-31 (IMP-e491c01f5c01).** This step
> previously showed `governance_dashboard()` returning an `alerts` array whose
> entries carried a signal `kind`. It returns no such thing:
> `Ai::Tools::GovernanceTool#governance_dashboard` returns COUNTS over
> `Ai::GovernanceReport` and `Ai::CollusionIndicator`, and reads no FleetEvent
> at all — so neither `system.honeypot_access` nor `system.honeypot_triggered`
> appears there. To see the honeypot events, use `platform.recent_events` as in
> Step 4.

Recommended response (the muscle memory you're building):

1. **Isolate** — `platform.system_sdwan_create_firewall_rule` to drop
   traffic to the affected instance pending forensics
2. **Snapshot** — provider snapshot of the instance disk for evidence
3. **Investigate** — `attribute_failure` to enumerate recent module/config
   changes; correlate with `journalctl` inside the instance
4. **Decide** — re-image, terminate, or restore from a known-good state

## Verification

**Event recorded:**

```javascript
platform.recent_events({ kind: "system.honeypot_triggered" })
// → at least one event with the right canary_path
```

**Escalation visible:**

```javascript
platform.recent_events({ kind: "system.honeypot_access" })
// → the sensor's escalation signal, if the reconciler has ticked
```

(The earlier text checked `governance_dashboard()` for an `alerts` array; it
has no such key — see the note in Step 5.)

**Sensor active:**

```javascript
// agent_introspect resolves by UUID only — resolve "Fleet Autonomy" first:
platform.list_agents()
// → { agents: [{ id: "<fleet-autonomy-uuid>", name: "Fleet Autonomy", ... }, ...] }
platform.agent_introspect({ agent_id: "<fleet-autonomy-uuid>" })
// → recent_executions include honeypot_access_sensor ticks
```

## Document the response

```javascript
platform.create_learning({
  title: "DRILL: Honeypot canary triggered on instance X — handler procedure",
  category: "discovery",
  content: "Drill rehearsal of canary detection. Operator response: isolate via firewall rule (5s), snapshot via provider API (2 min), attribute_failure run (60s), decision to re-image. Total MTTD (mean time to detect) from cat → dashboard alert: ~75s (60s sensor tick + 15s propagation). MTTR (mean time to remediate) for drill: ~5 min — acceptable for non-prod. Production target: sub-2-min MTTR via auto-isolate intervention policy.",
  tags: ["honeypot", "incident-response", "drill"],
  related_entities: [{ type: "instance", id: "..." }]
})
```

For **real incidents** (not drills), open an incident ticket via your IR
runbook. Honeypot triggers are never "noise" — investigate every one.

## Cleanup

```javascript
// Unassign the canary module (removes decoy files + stops watchers)
platform.system_unassign_module_from_template({
  template_id: "<template-id>",
  module_id: "<honeypot-canary-module-id>"
})

// Or terminate the test instance entirely
platform.system_terminate_instance({ instance_id: "<test-instance-id>" })
```

## Troubleshooting

**Sensor never fires** — three sub-cases:

- Inotify watcher daemon isn't running on the instance. SSH and check:
  `systemctl status powernode-honeypot-watcher.service`
- Agent isn't posting events. Check
  `platform.recent_events({ kind_prefix: "system.heartbeat" })` —
  if heartbeats are missing, the agent's offline.
- Sensor is disabled in the agent's intervention policy. Check via
  `platform.agent_introspect`.

**False positives from legitimate processes** — backup jobs, security
scanners, or operators reading canary paths during diagnostics. Two
fixes:

- Tune `canary_files` to genuinely never-touched paths
- Add an exception in the sensor: `accessing_process IN ('rsync', 'tripwire')`

**Multi-instance correlation** — if multiple instances trigger canaries
within minutes, lateral movement is likely; escalate to incident
immediately. Watch via:

```javascript
platform.recent_events({
  kind: "system.honeypot_triggered",
  since: "1 hour ago"
})
// → if >1 instance in the list, escalate
```

**Drill vs real** — always tag drill events explicitly (learning title
prefixed with `DRILL:`); never confuse drill response with real IR.

**Sub-minute alerts** — `honeypot_access_sensor` runs every 60s and only
considers events inside a fixed 15-minute lookback window (hardcoded
today; an env-configurable lookback is proposed). Access events older
than that window on the sensor's first tick after a long pause won't
re-escalate — they're already in the FleetEvent log. For faster
propagation than the 60s tick, push directly via WebSocket or escalate
via `send_proactive_notification`.

## What's next

- **[Tutorial 10 — GitOps fleet](./10-gitops-fleet.md)** — codify "every
  prod node gets honeypot-canary" in `fleet.yaml` so new nodes are
  automatically instrumented.
- **[`FLEET_SENSORS.md`](../FLEET_SENSORS.md)** — `honeypot_access_sensor`
  reference + the 16 other registered sensors that watch your fleet.
- **[`ARCHITECTURE.md`](../ARCHITECTURE.md)** §7 — Honeypot canary
  subsystem design.
- **Run drills quarterly** — same logic as CVE drills (Tutorial 07):
  muscle memory is what matters.

_Last verified: 2026-06-03 (rev 2)_
