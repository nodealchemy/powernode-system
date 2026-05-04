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
| Skill executors | `docs/SKILL_EXECUTORS.md` | `app/services/system/ai/skills/` (14 executors), `db/seeds/system_skills_seed.rb` |
| Disk image CI | `docs/DISK_IMAGE_CI.md` | `app/models/system/{disk_image_publication,disk_image_webhook}.rb`, `app/services/system/disk_image_*_service.rb` |
| CI workers + Gitea Actions | (cross-cuts disk image CI) | `app/services/system/{worker_dispatch,execution_dispatcher}.rb` |
| Tasks + autonomy reconcile | `docs/ARCHITECTURE.md` §4 | `app/models/system/task.rb`, `app/services/system/runtime_task_dispatcher.rb` |
| Honeypot canaries | `docs/ARCHITECTURE.md` §7 | `app/services/system/honeypot/canary_module_service.rb` |

## AI Agents (3)

The system extension seeds three AI agents with distinct trust scores + approval chains:

- **System Concierge** (`assistant`, chat) — operator chat agent. `concierge_tool_filter` covers `system_*`, `docker_*`, `kubernetes_*`, plus `discover_skills`/`get_skill_context`/`request_confirmation`. 4 read-shape skills bound. Seeded by `db/seeds/system_concierge_agent.rb`.
- **Fleet Autonomy** (`monitor`) — fleet-wide reconciler running every 60s. Cert rotation, SDWAN remediation, CVE response, drift remediation, module composition, rolling upgrades. 8 skills bound. 17 intervention policies. Seeded by `db/seeds/fleet_autonomy_agent.rb`.
- **Runtime Manager** (`monitor`) — Phase 1 Docker + Phase 2 K3s lifecycle. 2 skills bound (`docker_provision`, `provision_cluster`). 8 intervention policies. Distinct approval chain so container runtime changes route separately. Seeded by `db/seeds/system_runtime_manager_agent.rb`.

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

- `README.md` — extension overview
- `CONTRIBUTING.md` — submodule + commit workflow
- `docs/ARCHITECTURE.md` — 8 subsystems + 4 API surfaces + security architecture
- `docs/TASKS.md` — milestone status (auto-generated)
- `docs/SMOKE_TEST.md` — integration test checklist
- `docs/CONTAINER_RUNTIMES.md` — Phase 1 Docker + Phase 2 K3s operator guide (NEW)
- `docs/SKILL_EXECUTORS.md` — 14 executor reference (NEW)
- `docs/FLEET_SENSORS.md` — 13 sensor reference (NEW)
- `docs/DISK_IMAGE_CI.md` — webhook + CI worker workflow (NEW)
- `docs/threat-model.md` — security review
- `docs/agent-peering.md` — NodeInstance-as-Agent pattern (in sweep)
- `docs/credential-restoration.md` — Vault credential lifecycle
- `docs/gitops.md` — GitOps reconciler design (in sweep)
- `initramfs/README.md` — multi-arch boot builder
