# System Extension — CLAUDE.md

Powernode's system extension. Node lifecycle, modules, SDWAN, fleet autonomy, container runtimes, disk image CI, and the on-node Go agent.

This file is the index for AI sessions touching `extensions/system/`. Each domain points at its operator guide + critical source files.

## Capability Domains (10)

| Domain | Operator Guide | Key Source Files |
|---|---|---|
| Node lifecycle | `docs/ARCHITECTURE.md` §2 | `app/models/system/{node,node_instance,node_template,node_architecture,node_platform}.rb`, `app/services/system/{enrollment,bootstrap,provisioning,instance_control}_service.rb` |
| Modules + categories + assignments | `docs/ARCHITECTURE.md` §1 | `app/models/system/{node_module,node_module_category,node_module_assignment,node_module_version}.rb`, `app/services/system/{module_version,module_build,module_publication_processor,module_oci_ingest}_service.rb` |
| Container runtimes (Phase 1 Docker + Phase 2 K3s) | `docs/CONTAINER_RUNTIMES.md` | `app/services/system/docker_daemon_provisioner_service.rb`, `app/services/system/kubernetes_cluster_provisioner_service.rb`, `app/controllers/api/v1/system/node_api/runtime_controller.rb`, `agent/internal/dockerd/`, `agent/internal/k3sd/` |
| SDWAN (slices 1–9) | `docs/ARCHITECTURE.md` §5 | `app/models/sdwan/`, `app/services/sdwan/`, `app/controllers/api/v1/system/sdwan/` |
| Fleet autonomy + sensors | `docs/FLEET_SENSORS.md`, `docs/ARCHITECTURE.md` §4 | `app/services/system/fleet/sensors/`, `app/services/fleet_autonomy_service.rb`, `db/seeds/fleet_autonomy_agent.rb` |
| Skill executors | `docs/SKILL_EXECUTORS.md` | `app/services/system/ai/skills/` (29 executors), `db/seeds/system_skills_seed.rb` |
| Disk image CI | `docs/DISK_IMAGE_CI.md` | `app/models/system/{disk_image_publication,disk_image_webhook}.rb`, `app/services/system/disk_image_*_service.rb` |
| CI workers + Gitea Actions | (cross-cuts disk image CI) | `app/services/system/{worker_dispatch,execution_dispatcher}.rb` |
| Tasks + autonomy reconcile | `docs/ARCHITECTURE.md` §4 | `app/models/system/task.rb`, `app/services/system/runtime_task_dispatcher.rb` |
| Honeypot canaries | `docs/ARCHITECTURE.md` §7 | `app/services/system/honeypot/canary_module_service.rb` |

## AI Agents (5)

The system extension seeds five AI agents with distinct trust scores + approval chains. The 5-agent split (2026-05-10) replaced an earlier 3-agent model where Fleet Autonomy owned CVE, SDWAN, and Disk Image work — each domain now has its own queue so operators can pause one (e.g. SDWAN during maintenance) without halting the others.

- **System Concierge** (`assistant`, chat) — operator chat agent. `concierge_tool_filter` covers `system_*`, `docker_*`, `kubernetes_*`, plus `discover_skills`/`get_skill_context`/`request_confirmation`. 4 read-shape skills bound. Seeded by `db/seeds/system_concierge_agent.rb`.
- **Fleet Autonomy** (`monitor`) — non-CVE fleet reconciler running every 60s. Cert rotation, drift remediation, module composition, rolling upgrades, package repository/module ops. 10 skills bound. ~13 intervention policies (CVE policies moved to CVE Responder). Seeded by `db/seeds/fleet_autonomy_agent.rb`.
- **Runtime Manager** (`monitor`) — Phase 1 Docker + Phase 2 K3s lifecycle. 2 skills bound (`docker_provision`, `provision_cluster`). 8 intervention policies. Distinct approval chain so container runtime changes route separately. Seeded by `db/seeds/system_runtime_manager_agent.rb`.
- **CVE Responder** (`monitor`) — security-focused reconciler running every 60s via `SystemCveResponderReconcileJob`. Owns the full chain: CVE ingest (via hourly `SystemCveFeedJob`) → exposure scan → triage → critical-upgrade detection → orchestrated rebuild + rolling upgrade. 5 skills bound (`cve_response`, `cve_remediation_orchestration`, `cve_runbook_generate`, `rolling_module_upgrade`, `package_module_refresh`). 5 intervention policies. 8h approval timeout (security responses span business days). Seeded by `db/seeds/system_cve_responder_agent.rb`. Sensors live in `app/services/system/cve_ops/sensors/`: `CvePublishedSensor` emits `system.cve_critical_published` for fresh critical/high exposures; `CriticalUpgradeAvailableSensor` emits `system.module_critical_upgrade_ready` only when drift AND open CveExposure intersect (the "patch already exists, fly it" path which gets `notify_and_proceed`).
- **SDWAN Manager** (`monitor`) — owns SDWAN peer drift, hub reachability, BGP session health, VIP failover, route policy audit. Skills bound: `sdwan_*` executors. Seeded by `db/seeds/system_sdwan_manager_agent.rb` (2026-05-10). _Documentation pending; refer to the SDWAN sensors + plan files for current scope._
- **Disk Image Manager** (`monitor`) — owns disk image CI publication lifecycle (build → verify → promote → retention). Seeded by `db/seeds/system_disk_image_manager_agent.rb` (2026-05-10). _Documentation pending; refer to `docs/DISK_IMAGE_CI.md` for current scope._

## MCP Tools

System-extension MCP actions follow these prefixes:

- `system_*` — fleet ops, modules, instances, templates, tasks, container runtime provisioning, disk image CI
- `system_sdwan_*` — SDWAN management (~70 actions)
- `kubernetes_*` — Phase 2 K8s clusters (read + decommission + kubeconfig)
- `docker_*` — DockerHost CRUD + container/image/network/volume management (works on managed + external hosts)

The full action catalog regenerates via `cd server && bundle exec rails mcp:generate_tool_catalog` (gitignored at `docs/platform/MCP_TOOL_CATALOG.md`).

## Critical Conventions

### When adding a new capability

1. Always check existing skill executors before writing a new orchestration. 14 already cover most fleet/SDWAN/runtime workflows. See `docs/SKILL_EXECUTORS.md`.
2. New skills must have BOTH an executor at `app/services/system/ai/skills/<name>_executor.rb` AND an `Ai::Skill` record (seeded via `db/seeds/system_skills_seed.rb`).
3. New autonomy actions must have a `system.<action>` intervention policy entry in either `fleet_autonomy_agent.rb` or `system_runtime_manager_agent.rb`.
4. Cross-account safety: use `find_or_create_by` with `account: account` scoping. The KG seeds + skill seeds follow this pattern.

### Submodule mechanics

This is a git submodule. Per root CLAUDE.md:
- Always run `git rev-parse --show-toplevel` before `git add`/`commit`
- Commit inside the submodule first, then bump the parent's submodule pointer
- The system extension is dual-remoted: `origin` = private Gitea, `github` = public GitHub mirror (MIT)

### Test patterns

- RSpec specs under `server/spec/`
- Live smoke tests under `server/db/seeds/smoke_test_*.rb` — run via `cd server && rails runner "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_<name>.rb')"`
- Go agent tests under `agent/internal/*/` — run via `cd agent && go test ./...`

## Related Docs

### Reference

- `README.md` — extension overview
- `CONTRIBUTING.md` — submodule + commit workflow
- `docs/ARCHITECTURE.md` — 8 subsystems + 4 API surfaces + security architecture
- `docs/TASKS.md` — milestone status (auto-generated)
- `docs/SMOKE_TEST.md` — integration test checklist
- `docs/CONTAINER_RUNTIMES.md` — Phase 1 Docker + Phase 2 K3s operator guide + troubleshooting
- `docs/USE_CASE_MATRIX.md` — what works / what doesn't / what to expect for 10 NodeInstance container use cases (READ FIRST when designing a deployment)
- `docs/SKILL_EXECUTORS.md` — 29 executor reference (with example I/O)
- `docs/FLEET_SENSORS.md` — 12 sensor reference + intervention policy table
- `docs/DISK_IMAGE_CI.md` — webhook + CI worker workflow
- `docs/MCP_API_REFERENCE.md` — `system_*` / `system_sdwan_*` / `kubernetes_*` / `docker_*` MCP tool actions
- `docs/agent-peering.md` — NodeInstance-as-Agent pattern (in sweep)
- `docs/credential-restoration.md` — Vault credential lifecycle
- `docs/gitops.md` — GitOps reconciler design (in sweep)
- `initramfs/README.md` — multi-arch boot builder

### Operator runbooks (`docs/runbooks/`)

- `node-provisioning.md` — full Node + NodeInstance lifecycle with per-state error recovery
- `sdwan-network-setup.md` — SDWAN end-to-end (networks, peers, VIPs, firewall, BGP, federation)
- `module-authoring.md` — author + register + sign + publish a new NodeModule
- `cve-response.md` — full CVE response workflow (SBOM-aware matching, triage, remediation)
- `instance-pool-tuning.md` — pool sizing + reaping (slice 7)
- `multi-cluster-k3s.md` — multi-cluster K3s with `metadata.target_cluster_id` + HA control plane
- `disk-image-ci.md` — disk image CI operator workflow
- `vault-credential-restoration.md` — DR runbook for credential restoration

### Use-case examples (`docs/examples/`)

10 end-to-end walkthroughs (`01-single-node-qemu.md` through `10-gitops-fleet.md`). Six have companion runnable seeds at `server/db/seeds/example_*.rb`.

### External references (live in parent platform)

- `<parent>/docs/system/threat-model.md` — STRIDE threat analysis across 6 attack surfaces (operator API, worker API, node API, MCP tools, internal CA, GitHub mirror)
