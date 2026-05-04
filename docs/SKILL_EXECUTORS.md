# Skill Executors — System Extension Reference

The system extension ships 14 skill executors at `extensions/system/server/app/services/system/ai/skills/`. Each pairs with an `Ai::Skill` record (seeded by `system_skills_seed.rb`) that makes it discoverable via `platform.discover_skills`. Skills are bound to autonomy + chat agents via `Ai::AgentSkill`.

## Agent → Skill Bindings

| Skill | Bound To | Why |
|---|---|---|
| `system-capacity-recommend` | System Concierge | Read-shape — operator chat ("do I need more nodes?") |
| `system-attribute-failure` | System Concierge | Read-shape — diagnostic chat ("why did instance X fail?") |
| `system-runbook-generate` | System Concierge | Read-shape — generates docs |
| `system-cve-runbook-generate` | System Concierge | Read-shape — generates docs |
| `system-drift-remediate` | Fleet Autonomy | Autonomous reconciliation |
| `system-cve-response` | Fleet Autonomy | Autonomous CVE triage |
| `system-sdwan-failover` | Fleet Autonomy | Autonomous SDWAN remediation |
| `system-sdwan-peer-remediate` | Fleet Autonomy | Autonomous SDWAN remediation |
| `system-sdwan-bgp-session-remediate` | Fleet Autonomy | Autonomous SDWAN remediation |
| `system-sdwan-vip-failover` | Fleet Autonomy | Autonomous SDWAN remediation |
| `system-module-compose` | Fleet Autonomy | Autonomous module planning |
| `system-rolling-module-upgrade` | Fleet Autonomy | Autonomous release planning |
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

## Related Docs

- `extensions/system/docs/CONTAINER_RUNTIMES.md` — `docker_provision` + `provision_cluster` integration
- `extensions/system/docs/FLEET_SENSORS.md` — sensor signals that trigger autonomous skill invocation
- `extensions/system/docs/ARCHITECTURE.md` — autonomy + decision engine subsystem
