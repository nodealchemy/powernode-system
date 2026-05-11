# Skill Executors — System Extension Reference

The system extension ships 29 skill executors at `extensions/system/server/app/services/system/ai/skills/`. Each pairs with an `Ai::Skill` record (seeded by `system_skills_seed.rb`) that makes it discoverable via `platform.discover_skills`. Skills are bound to autonomy + chat agents via `Ai::AgentSkill`.

> The per-executor reference section below covers the original 14 executors in depth. The 15 newer executors (CVE remediation orchestration, full-stack provisioning, package management, SDWAN OVN composition, IPFIX collector, workload relocation, etc.) have inline documentation in their source files and `descriptor()` blocks; expanding this reference is tracked separately.

## Agent → Skill Bindings (2026-05-11 — 5-agent split complete)

The 2026-05-10 agent split moved CVE work out of Fleet Autonomy into a dedicated **CVE Responder** agent. The full current binding map:

| Skill | Bound To | Why |
|---|---|---|
| `system-capacity-recommend` | System Concierge | Read-shape — operator chat ("do I need more nodes?") |
| `system-attribute-failure` | System Concierge | Read-shape — diagnostic chat ("why did instance X fail?") |
| `system-runbook-generate` | System Concierge | Read-shape — generates docs |
| `system-cve-runbook-generate` | System Concierge **+** CVE Responder | Read-shape — generates CVE remediation runbooks |
| `system-drift-remediate` | Fleet Autonomy | Autonomous reconciliation |
| `system-sdwan-failover` | Fleet Autonomy | Autonomous SDWAN remediation |
| `system-sdwan-peer-remediate` | Fleet Autonomy | Autonomous SDWAN remediation |
| `system-sdwan-bgp-session-remediate` | Fleet Autonomy | Autonomous SDWAN remediation |
| `system-sdwan-vip-failover` | Fleet Autonomy | Autonomous SDWAN remediation |
| `system-module-compose` | Fleet Autonomy | Autonomous module planning |
| `system-rolling-module-upgrade` | Fleet Autonomy **+** CVE Responder | Autonomous release planning (CVE-driven via CVE Responder) |
| `system-package-repository-sync` | Fleet Autonomy | Autonomous package catalog sync |
| `system-package-module-create` | Fleet Autonomy | Autonomous package-derived module creation |
| `system-package-module-refresh` | Fleet Autonomy **+** CVE Responder | Autonomous package drift refresh (CVE-driven via CVE Responder) |
| `system-cve-response` | CVE Responder | CVE triage (moved from Fleet Autonomy 2026-05-11) |
| `system-cve-remediation-orchestration` | CVE Responder | Chains triage → refresh → rolling upgrade for inline notify_and_proceed dispatch |
| `system-provision-cluster` | Runtime Manager | Container runtime lifecycle (Phase 2 K3s) |
| `system-docker-provision` | Runtime Manager | Container runtime lifecycle (Phase 1 Docker) |

## Pattern: Plan vs Execute

Every executor implements:
```ruby
def self.descriptor → { name, description, category, inputs, outputs }
def initialize(account:, agent:, user:)
def execute(**inputs) → { success: true, data: {...} } | { success: false, error: "..." }
```

Most fleet/SDWAN executors support `dry_run: true` mode — return the *plan* without side effects. The Fleet Autonomy reconciler uses dry-run for sensor analysis, then commits via `dry_run: false` once approval policies allow.

## Per-Executor Reference

### `attribute_failure` — Failure analysis

**Source:** `attribute_failure_executor.rb`
**Category:** `sre_observability` (subdomain: `fleet`)
**Inputs:** `instance_id` (required), `lookback_hours` (default 24)
**Outputs:** `candidates`, `top_candidate`, `confidence`, `reasoning`

Given a failed NodeInstance, ranks recent module changes + version promotions in the lookback window by likelihood of being the cause. Returns a structured rationale operators can read in chat or paste into a postmortem.

### `capacity_recommend` — Fleet sizing

**Source:** `capacity_recommend_executor.rb`
**Category:** `sre_observability` (subdomain: `fleet`)
**Inputs:** `template_id` (required), `target_min_active` (default from constant)
**Outputs:** `template_id`, `total_count`, `active_count`, `silent_count`, `errored_count`, `recommendation`, `confidence`

Looks at heartbeat health + module assignment density across a Template's instances. Returns a sized recommendation (e.g. "+2 instances") with a confidence label.

### `cve_response` — CVE triage

**Source:** `cve_response_executor.rb`
**Category:** `security` (subdomain: `cve`)
**Inputs:** `cve_id`, `severity`, `affected_packages`, `summary` (optional)
**Outputs:** `risk_score`, `exposed_modules`, `exposed_instance_count`, `remediation_plan`, `requires_approval`

Triages a CVE against the fleet — enumerates exposure, scores risk, proposes a remediation plan. Sets `requires_approval=true` when the plan touches >5% of fleet instances.

### `cve_runbook_generate` — CVE remediation runbook

**Source:** `cve_runbook_generate_executor.rb`
**Category:** `security` (subdomain: `cve`)
**Inputs:** `cve_id`, `persist_as_page` (default false)
**Outputs:** `runbook_markdown`, `exposed_module_count`, `exposed_instance_count`, `risk_score`, `requires_approval`, `persisted_page_id`

Generates a markdown remediation runbook for a CVE — exposed modules, recommended steps, verification commands. Optionally persists as a Pages document for operator team review.

### `docker_provision` (Phase 1) — Docker daemon provisioning

**Source:** `docker_provision_executor.rb`
**Category:** `devops` (subdomain: `runtime`)
**Inputs:** `node_instance_id` (required), `dry_run` (default false)
**Outputs:** `host_id`, `host_status`, `api_endpoint`, `already_provisioned`, `plan` (dry_run only)

Wraps `System::DockerDaemonProvisionerService.provision!` for skill-based dispatch. Idempotent — `already_provisioned: true` on re-call. Bound to Runtime Manager.

### `drift_remediate` — Module reconciliation

**Source:** `drift_remediate_executor.rb`
**Category:** `sre_observability` (subdomain: `fleet`)
**Inputs:** `instance_id` (required), `max_disruption_pct` (default 20)
**Outputs:** `resolved`, `requires_approval`, `disruption_pct`, `planned_actions: { attach, detach, update }`

Reconciles a NodeInstance's running modules against its assigned modules. Returns planned attach/detach/update actions with disruption %. Sets `requires_approval=true` when disruption exceeds threshold.

### `module_compose` — Template draft from workload description

**Source:** `module_compose_executor.rb`
**Category:** `devops` (subdomain: `modules`)
**Inputs:** `description` (free text), `platform_id` (optional), `max_modules`
**Outputs:** `draft_template`, `conflicts`, `candidate_count`, `reasoning`

Keyword-matches modules against a workload description. Useful when an operator describes a workload ("nginx with TLS") and wants a starter Template draft.

### `provision_cluster` (Phase 2) — Cluster bootstrap

**Source:** `provision_cluster_executor.rb`
**Category:** `devops` (subdomain: `fleet`)
**Inputs:** `template_id`, `count` (1-50), `provider_region_id`, `provider_instance_type_id`, `name_prefix`, `dry_run`
**Outputs:** `count`, `created_nodes`, `provisioned`, `failures`, `partial`, `plan` (dry_run only)

Composes `system_create_node` + `system_provision_instance` per node. Hard cap at 50 instances per call — larger rolls go through `rolling_module_upgrade` with explicit operator approval. Bound to Runtime Manager.

### `rolling_module_upgrade` — Batched fleet upgrade

**Source:** `rolling_module_upgrade_executor.rb`
**Category:** `release_management` (subdomain: `modules`)
**Inputs:** `template_id`, `module_id`, `target_version_id`, `batch_pct` (default), `max_consecutive_failures`, `health_timeout_sec`
**Outputs:** `total_instances`, `batch_size`, `batch_count`, `estimated_total_seconds`, `circuit_breaker`, `batches`

Plans a circuit-breaker-protected rolling upgrade. The executor returns a *plan*; the autonomy reconciler executes it batch-by-batch, gating on health between batches.

### `runbook_generate` — Template runbook

**Source:** `runbook_generate_executor.rb`
**Category:** `documentation` (subdomain: `docs`)
**Inputs:** `template_id`, `persist_as_page` (default false)
**Outputs:** `runbook_markdown`, `section_count`, `persisted_page_id`, `source_artifacts`

Generates a markdown operational runbook for a Template — boot order, common failure modes, recovery procedures. Optionally persists as a Pages document.

### `sdwan_bgp_session_remediate` — iBGP session triage

**Source:** `sdwan_bgp_session_remediate_executor.rb`
**Category:** `sre_observability` (subdomain: `sdwan`)
**Inputs:** `bgp_session_id` OR (`peer_id` + `neighbor_address`), `dry_run` (default true)
**Outputs:** `resolved`, `session_id`, `state`, `likely_cause`, `recommended_action`

Triages an unhealthy iBGP session. v1 returns analysis only — does NOT auto-restart FRR. Operators run the recommended command after review.

### `sdwan_failover` — Hub failover planning

**Source:** `sdwan_failover_executor.rb`
**Category:** `sre_observability` (subdomain: `sdwan`)
**Inputs:** `network_id`, `dry_run` (default true)
**Outputs:** `resolved`, `network_id`, `current_hub_count`, `candidate_count`, `candidates`

Identifies hub-promotion candidates when a network's hub is unreachable. Returns spokes ranked by `last_handshake_at`. v1 only supports planning — operator manually flips `publicly_reachable=true` after review.

### `sdwan_peer_remediate` — Peer key rotation

**Source:** `sdwan_peer_remediate_executor.rb`
**Category:** `sre_observability` (subdomain: `sdwan`)
**Inputs:** `peer_id`, `dry_run` (default false)
**Outputs:** `resolved`, `rotated_from_key_id`, `new_key_id`, `new_public_key`

Rotates an SDWAN peer's WireGuard keypair. The agent re-establishes the tunnel from a clean key on its next reconcile.

### `sdwan_vip_failover` — Virtual IP failover

**Source:** `sdwan_vip_failover_executor.rb`
**Category:** `sre_observability` (subdomain: `sdwan`)
**Inputs:** `virtual_ip_id`, `dry_run` (default false)
**Outputs:** `resolved`, `virtual_ip_id`, `previous_holder_peer_id`, `new_holder_peer_id`, `anycast`

Promotes the next failover candidate of a silent-holder VIP. Anycast VIPs return informational only (failover handled by routing).

## How Executors Get Invoked

**Path A — direct skill execution** (chat agent):
```
operator chat → System Concierge → discover_skills(task) → get_skill_context(slug)
  → build args from chat context → System::Ai::Skills::*Executor.new.execute(...)
```

**Path B — autonomy decision loop** (monitor agent):
```
Fleet Autonomy reconciler → sensors emit signals → DecisionEngine
  → policy match (auto_approve / notify_and_proceed / require_approval)
  → if allowed: System::Ai::Skills::*Executor.new.execute(...)
  → if require_approval: ApprovalRequest queued, operator reviews
```

**Path C — workspace task** (multi-agent coordination):
```
Workspace mission → spawn task → agent picks executor by name
  → execute(...) returns structured result → next task in mission
```

## Adding a New Executor

1. Create `extensions/system/server/app/services/system/ai/skills/<name>_executor.rb`. Match the canonical shape:
   ```ruby
   module System::Ai::Skills
     class FoobarExecutor
       def self.descriptor = { name: "foobar", description: "...", category: "...", inputs: {...}, outputs: {...} }
       def initialize(account:, agent: nil, user: nil)
       def execute(**inputs) = { success: bool, data: {...} } | { success: false, error: "..." }
     end
   end
   ```
2. Add the skill to `extensions/system/server/db/seeds/system_skills_seed.rb`. Map the executor's `descriptor[:category]` to a platform `Ai::Skill` enum value (`devops`, `security`, `sre_observability`, `release_management`, `documentation`).
3. Bind to an agent in the appropriate seed (`system_concierge_agent.rb`, `fleet_autonomy_agent.rb`, or `system_runtime_manager_agent.rb`).
4. Re-run seeds: `cd server && bundle exec rails db:seed`.
5. Verify discoverability: `platform.discover_skills query: "your task"` should return the new skill.

## Example Inputs and Outputs

Every executor returns `{ success: true, data: {...} }` on the happy path or `{ success: false, error: "..." }` on failure. The `data` shape per executor:

### `attribute_failure`

```json
// Input
{ "instance_id": "0193cdef-1234-7890-abcd-001122334455", "lookback_hours": 24 }

// Output (success.data)
{
  "candidates": [
    { "kind": "module_promotion", "module": "nginx", "from_version": "1.24.0", "to_version": "1.26.0",
      "promoted_at": "2026-05-04T08:12:30Z", "score": 0.74,
      "reason": "version promoted within 1.5h before instance went silent" },
    { "kind": "module_assignment_change", "module": "tls-config", "action": "attached",
      "changed_at": "2026-05-04T08:55:12Z", "score": 0.41 }
  ],
  "top_candidate": { "kind": "module_promotion", "module": "nginx", "score": 0.74 },
  "confidence": "medium",
  "reasoning": "Most recent change in lookback window: nginx 1.24→1.26 promoted at 08:12; instance silent at 09:30. Module-promote pattern with high recency."
}
```

### `capacity_recommend`

```json
// Input
{ "template_id": "tmpl-abc-7890", "target_min_active": 3 }

// Output (success.data)
{
  "template_id": "tmpl-abc-7890",
  "total_count": 5,
  "active_count": 2,
  "silent_count": 2,
  "errored_count": 1,
  "recommendation": { "action": "scale_up", "delta": 1, "rationale": "active=2 < target_min_active=3" },
  "confidence": "low"
}
```

`confidence: "low"` is the v0 default — real telemetry (M-D2-2) will lift this.

### `cve_response`

```json
// Input
{
  "cve_id": "CVE-2026-12345",
  "severity": "critical",
  "affected_packages": [{ "name": "openssl", "version": "<3.1.4" }],
  "summary": "Buffer overflow in OpenSSL TLS handshake"
}

// Output (success.data)
{
  "cve_id": "CVE-2026-12345",
  "severity": "critical",
  "risk_score": 85,
  "exposed_modules": [
    { "id": "mod-abc", "name": "system-base", "assignment_count": 12 },
    { "id": "mod-def", "name": "nginx",        "assignment_count": 8 }
  ],
  "exposed_instance_count": 20,
  "remediation_plan": {
    "actions": [
      { "module": "system-base", "from_version": "1.0.3", "to_version": "1.0.4", "instance_count": 12 },
      { "module": "nginx",       "from_version": "1.24.0", "to_version": "1.26.0", "instance_count": 8 }
    ],
    "estimated_seconds": 2400
  },
  "requires_approval": true
}
```

`requires_approval=true` because risk_score ≥ AUTO_GATE_RISK_THRESHOLD (50).

### `cve_runbook_generate`

```json
// Input
{ "cve_id": "CVE-2026-12345", "persist_as_page": true }

// Output (success.data)
{
  "runbook_markdown": "# CVE-2026-12345 — Remediation Runbook\n\n## Exposure\n\n- 2 NodeModules affected (system-base, nginx)\n- 20 NodeInstances exposed\n\n## Steps\n\n1. ...\n",
  "exposed_module_count": 2,
  "exposed_instance_count": 20,
  "risk_score": 85,
  "requires_approval": true,
  "persisted_page_id": "page-cve-2026-12345"
}
```

### `docker_provision`

```json
// Input (live)
{ "node_instance_id": "0193cdef-1234-7890-abcd-001122334455", "dry_run": false }

// Output (success.data, live)
{
  "dry_run": false,
  "host_id": "host-9876",
  "host_status": "pending",
  "api_endpoint": "tcp://[fd00:abcd:1::42]:2376",
  "already_provisioned": false
}

// Output (success.data, dry_run)
{
  "dry_run": true,
  "plan": {
    "node_instance_id": "0193cdef-...",
    "sdwan_peer_address": "fd00:abcd:1::42",
    "actions": [
      "Mint client mTLS cert via InternalCaService",
      "Create Devops::DockerHost row (status=pending)",
      "Wait for agent to install docker-ce + report phase=ready"
    ]
  }
}
```

`already_provisioned: true` is returned (with no side effects) when a managed host already exists — idempotent.

### `drift_remediate`

```json
// Input
{ "instance_id": "0193cdef-1234-7890-abcd-001122334455", "max_disruption_pct": 20 }

// Output (success.data, drift detected)
{
  "resolved": false,
  "requires_approval": false,
  "disruption_pct": 20,
  "planned_actions": {
    "attach": ["security-hardening"],
    "detach": [],
    "update": ["nginx (1.24.0 → 1.26.0)"]
  },
  "note": "auto-apply pending M7 reconciler",
  "drift_report": { "/* full system_drift_report payload */": null }
}

// Output (success.data, no drift)
{ "resolved": true, "requires_approval": false, "disruption_pct": 0, "planned_actions": { "attach": [], "detach": [], "update": [] }, "reason": "no drift" }
```

5 changes ≈ 100% disruption (linear v0 model). `requires_approval=true` when `disruption_pct > max_disruption_pct`.

### `module_compose`

```json
// Input
{ "description": "nginx with TLS termination + rate limiting", "platform_id": "platform-abc", "max_modules": 5 }

// Output (success.data)
{
  "draft_template": {
    "name_suggestion": "nginx-tls-rate-limited",
    "modules": [
      { "name": "system-base", "priority": 10, "reason": "always required" },
      { "name": "security-hardening", "priority": 20, "reason": "TLS hardening baseline" },
      { "name": "nginx", "priority": 50, "reason": "keyword match: nginx" }
    ]
  },
  "conflicts": [],
  "candidate_count": 3,
  "reasoning": "Matched 'nginx' (nginx module), 'TLS' (security-hardening). Rate limiting requires custom config — recommend operator add a config-variety override module."
}
```

### `provision_cluster`

```json
// Input (live)
{
  "template_id": "tmpl-k3s-template",
  "count": 3,
  "provider_region_id": "region-aws-us-east-1",
  "provider_instance_type_id": "type-t3-medium",
  "name_prefix": "k3s-prod",
  "dry_run": false
}

// Output (success.data, live)
{
  "count": 3,
  "created_nodes": ["node-1", "node-2", "node-3"],
  "provisioned": 3,
  "failures": [],
  "partial": false
}

// Output (success.data, dry_run)
{
  "count": 3,
  "plan": {
    "actions": [
      "Create 3 Node rows with name_prefix=k3s-prod",
      "Provision 3 NodeInstances in region us-east-1, type t3.medium",
      "First instance gets k3s-server module assignment; remaining get k3s-agent"
    ],
    "estimated_seconds": 600
  }
}
```

Hard-capped at 50 per call — larger fleets go through `rolling_module_upgrade`.

### `rolling_module_upgrade`

```json
// Input
{ "template_id": "tmpl-abc", "module_id": "mod-nginx", "target_version_id": "v-1.26.0",
  "batch_pct": 20, "max_consecutive_failures": 2, "health_timeout_sec": 300 }

// Output (success.data)
{
  "total_instances": 50,
  "batch_size": 10,
  "batch_count": 5,
  "estimated_total_seconds": 1500,
  "circuit_breaker": { "max_consecutive_failures": 2, "tripped_after_seconds": null },
  "batches": [
    { "index": 0, "instance_ids": ["..."], "phase": "pending" },
    { "index": 1, "instance_ids": ["..."], "phase": "pending" }
  ]
}
```

The autonomy reconciler executes the plan batch-by-batch. Health checks between batches; trips circuit breaker after `max_consecutive_failures`.

### `runbook_generate`

```json
// Input
{ "template_id": "tmpl-abc", "persist_as_page": true }

// Output (success.data)
{
  "runbook_markdown": "# nginx-tls Runbook\n\n## Boot order\n\n1. system-base\n2. security-hardening\n3. nginx\n\n## Common failure modes\n\n- ...\n",
  "section_count": 6,
  "persisted_page_id": "page-tmpl-abc-runbook",
  "source_artifacts": ["module_manifest:system-base", "module_manifest:nginx"]
}
```

### `sdwan_bgp_session_remediate`

```json
// Input
{ "bgp_session_id": "bgp-sess-abc", "dry_run": true }

// Output (success.data)
{
  "resolved": false,
  "session_id": "bgp-sess-abc",
  "state": "idle",
  "likely_cause": "wrong AS number on neighbor (expected 65000, observed 65001)",
  "recommended_action": "vtysh -c 'show ip bgp summary' on the holding peer to confirm; then `clear ip bgp <neighbor>` to force re-handshake"
}
```

v1 is planning-only — never auto-restarts FRR. The recommended `clear ip bgp` command is operator-driven.

### `sdwan_failover`

```json
// Input
{ "network_id": "sdwan-net-abc", "dry_run": true }

// Output (success.data)
{
  "resolved": false,
  "network_id": "sdwan-net-abc",
  "current_hub_count": 1,
  "candidate_count": 2,
  "candidates": [
    { "peer_id": "peer-spoke-A", "last_handshake_at": "2026-05-04T09:30:12Z", "score": 0.92 },
    { "peer_id": "peer-spoke-B", "last_handshake_at": "2026-05-04T09:28:55Z", "score": 0.84 }
  ]
}
```

### `sdwan_peer_remediate`

```json
// Input
{ "peer_id": "peer-abc", "dry_run": false }

// Output (success.data)
{
  "resolved": true,
  "rotated_from_key_id": "key-old-abc",
  "new_key_id": "key-new-def",
  "new_public_key": "AbCd...EfGh="
}
```

The agent picks up the new key on its next reconcile (~30 s) and re-establishes the WireGuard tunnel.

### `sdwan_vip_failover`

```json
// Input (single-holder VIP, live)
{ "virtual_ip_id": "vip-abc", "dry_run": false }

// Output (success.data)
{
  "resolved": true,
  "virtual_ip_id": "vip-abc",
  "previous_holder_peer_id": "peer-old",
  "new_holder_peer_id": "peer-new",
  "anycast": false
}

// Output for anycast VIP
{
  "resolved": false,
  "virtual_ip_id": "vip-abc",
  "previous_holder_peer_id": null,
  "new_holder_peer_id": null,
  "anycast": true,
  "note": "Anycast VIPs use routing for failover; this skill is informational only for anycast."
}
```

## Related Docs

- `extensions/system/docs/CONTAINER_RUNTIMES.md` — `docker_provision` + `provision_cluster` integration
- `extensions/system/docs/FLEET_SENSORS.md` — sensor signals that trigger autonomous skill invocation
- `extensions/system/docs/ARCHITECTURE.md` — autonomy + decision engine subsystem
- `extensions/system/docs/runbooks/cve-response.md` — CVE response operator runbook (uses `cve_response` + `cve_runbook_generate` + `rolling_module_upgrade`)
- `extensions/system/docs/runbooks/sdwan-network-setup.md` — SDWAN runbook (uses `sdwan_failover` + `sdwan_peer_remediate` + `sdwan_vip_failover`)
