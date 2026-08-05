# System Extension — CLAUDE.md

Powernode's system extension. Node lifecycle, modules, SDWAN, fleet autonomy, container runtimes, disk image CI, and the on-node Go agent.

This file is the index for AI sessions touching `extensions/system/`. Each domain points at its operator guide + critical source files.

## Capability Domains (12)

| Domain | Operator Guide | Key Source Files |
|---|---|---|
| Node lifecycle | `docs/ARCHITECTURE.md` §2 (On-node runtime + NodeInstance lifecycle) | `app/models/system/{node,node_instance,node_template,node_architecture,node_platform}.rb`, `app/services/system/{enrollment,bootstrap,provisioning,instance_control}_service.rb` |
| Modules + categories + assignments | `docs/ARCHITECTURE.md` §1 | `app/models/system/{node_module,node_module_category,node_module_assignment,node_module_version}.rb`, `app/services/system/{module_version,module_build,module_publication_processor,module_oci_ingest}_service.rb` |
| Container runtimes (Phase 1 Docker + Phase 2 K3s) | `docs/CONTAINER_RUNTIMES.md` | `app/services/system/docker_daemon_provisioner_service.rb`, `app/services/system/kubernetes_cluster_provisioner_service.rb`, `app/controllers/api/v1/system/node_api/runtime_controller.rb`, `agent/internal/dockerd/`, `agent/internal/k3sd/` |
| SDWAN (slices 1–9) | `docs/SDWAN_ARCHITECTURE.md` (compile pipeline), `docs/SDWAN_MANAGER_AGENT.md`, `docs/runbooks/sdwan-network-setup.md` | `app/models/sdwan/`, `app/services/sdwan/`, `app/controllers/api/v1/system/sdwan/` |
| Service exposure (`Sdwan::Service`) | `docs/runbooks/publish-service.md` | `app/models/sdwan/service.rb`, `app/services/sdwan/service_exposure_writer.rb` (local `/svc/<slug>` + ForwardAuth), `app/controllers/api/v1/system/ingress/forward_auth_controller.rb`, `app/services/ai/tools/system_ingress_tool.rb`; federated facet = `Federation::ServiceOffering` |
| Fleet autonomy + sensors | `docs/FLEET_SENSORS.md`, `docs/ARCHITECTURE.md` §4 | `app/services/system/fleet/sensors/`, `app/services/fleet_autonomy_service.rb`, `db/seeds/fleet_autonomy_agent.rb` |
| Skill executors | `docs/SKILL_EXECUTORS.md` | `app/services/system/ai/skills/` (54 executor classes, 53 with `binds_to`), `db/seeds/system_skills_seed.rb` + `db/seeds/system_provisioning_skills_seed.rb` (BOTH seed `Ai::Skill` rows — check both before adding one) |
| Disk image CI | `docs/DISK_IMAGE_CI.md` | `app/models/system/{disk_image_publication,disk_image_webhook}.rb`, `app/services/system/disk_image_*_service.rb` |
| CI workers + Gitea Actions | (cross-cuts disk image CI) | `app/services/system/{worker_dispatch,execution_dispatcher}.rb` |
| Tasks + autonomy reconcile | `docs/ARCHITECTURE.md` §4 | `app/models/system/task.rb`, `app/services/system/execution_dispatcher.rb` |
| Honeypot canaries | `docs/ARCHITECTURE.md` §7 | `app/services/system/honeypot/canary_module_service.rb` |
| Storage (volumes, mounts, migration, chown) | `docs/STORAGE_SUBSYSTEM.md`, `docs/runbooks/storage-migration.md` | `app/models/system/{provider_volume,storage_assignment,storage_migration,storage_credential}.rb`, `app/services/system/storage/`, `app/services/ai/tools/{system_fleet_tool,system_storage_owner_tool}.rb` |

## AI Agents (8)

The system extension seeds eight AI agents with distinct trust scores + approval chains. The 2026-05-10 split brought Concierge + Fleet Autonomy + Runtime Manager + CVE Responder + SDWAN Manager + Disk Image Manager — replacing an earlier 3-agent model where Fleet Autonomy owned CVE, SDWAN, and Disk Image work. Phase O6 then added System Topology Designer as the first specialist in the cross-cutting design track, and the GitOps Reconciler closed the declarative-reconciliation gap (proposals previously attributed to an arbitrary agent). Each domain has its own queue so operators can pause one (e.g. SDWAN during maintenance) without halting the others. Note: Fleet Autonomy's seed file is `db/seeds/fleet_autonomy_agent.rb` (no `system_` prefix — predates the naming convention); the others follow `db/seeds/system_<name>_agent.rb`.

- **System Concierge** (`assistant`, chat) — operator chat agent. `concierge_tool_filter` covers `system_*`, `docker_*`, `kubernetes_*`, plus `discover_skills`/`get_skill_context`/`request_confirmation`. **25 skills bound**: 12 read-shape, 12 state-changing (incl. `system-fulfill-capability-request`, the end-to-end "purpose → node" path), plus the executor-less `system-provision-infrastructure` front door. The full split lives in the seeded prompt — `db/seeds/system_concierge_agent.rb` is the source of truth; do not re-list it here, it drifts.
- **Fleet Autonomy** (`monitor`) — non-CVE fleet reconciler running every 60s. Cert rotation, drift remediation, module composition, rolling upgrades, package repository/module ops, architecture catalog mutations. 10 skills bound. 27 intervention policies (after the 2026-05-10 split moved CVE → CVE Responder, operator SDWAN CRUD → SDWAN Manager, and Disk Image → Disk Image Manager; the autonomous `system.sdwan_*` remediations remain here) — see [`docs/FLEET_SENSORS.md`](./docs/FLEET_SENSORS.md) §Intervention Policy Reference). Seeded by `db/seeds/fleet_autonomy_agent.rb`.
- **Runtime Manager** (`monitor`) — Phase 1 Docker + Phase 2 K3s lifecycle. 2 skills bound (`docker_provision`, `provision_cluster`). 7 intervention policies (the `system.runtime_docker_tls_rotate` policy was removed during the 2026-05-19 audit — no executor existed; operators rotate Docker daemon TLS via the broader `system.cert_rotate` flow). Distinct approval chain so container runtime changes route separately. Seeded by `db/seeds/system_runtime_manager_agent.rb`.
- **CVE Responder** (`monitor`) — security-focused reconciler running every 60s via `SystemCveResponderReconcileJob`. Owns the full chain: CVE ingest (via hourly `SystemCveFeedJob`) → exposure scan → triage → critical-upgrade detection → orchestrated rebuild + rolling upgrade. 5 skills bound (`cve_response`, `cve_remediation_orchestration`, `cve_runbook_generate`, `rolling_module_upgrade`, `package_module_refresh`). 5 intervention policies. 8h approval timeout (security responses span business days). Seeded by `db/seeds/system_cve_responder_agent.rb`. Sensors live in `app/services/system/cve_ops/sensors/`: `CvePublishedSensor` emits `system.cve_critical_published` for fresh critical/high exposures; `CriticalUpgradeAvailableSensor` emits `system.module_critical_upgrade_ready` only when drift AND open CveExposure intersect (the "patch already exists, fly it" path which gets `notify_and_proceed`).
- **SDWAN Manager** (`monitor`) — owns SDWAN peer drift, hub reachability, BGP session health, VIP failover, route policy audit, and operator-initiated SDWAN CRUD. 24 intervention policies; 4h approval timeout. Skills bound: `sdwan_*` reconciliation executors. Seeded by `db/seeds/system_sdwan_manager_agent.rb` (2026-05-10). Operator guide: [`docs/SDWAN_MANAGER_AGENT.md`](./docs/SDWAN_MANAGER_AGENT.md).
- **Disk Image Manager** (`monitor`) — owns disk image CI publication lifecycle (build → verify → promote → retention). 6 intervention policies; 12h approval timeout; 5-minute tick. Seeded by `db/seeds/system_disk_image_manager_agent.rb` (2026-05-10). Operator guide: [`docs/DISK_IMAGE_MANAGER_AGENT.md`](./docs/DISK_IMAGE_MANAGER_AGENT.md). For the upstream CI pipeline see [`docs/DISK_IMAGE_CI.md`](./docs/DISK_IMAGE_CI.md).
- **System Topology Designer** (`assistant`) — specialist agent for cross-cutting platform topology design (Phase O6, first specialist in the cross-cutting design track). Charter: SDWAN composition today (host bridges, OVN logical networks, IPFIX collectors); container networking + storage topology in future. Invoked by Concierge via `execute_agent` for topology composition. 5 compose skills bound: `system-sdwan-host-bridge-compose`, `system-sdwan-ovn-compose-topology`, `system-sdwan-ipfix-collector-compose`, `system-sdwan-compose-full-topology`, `system-sdwan-ovn-apply-acl`. Trust tier: monitored. Seeded by `db/seeds/system_topology_designer_agent.rb`.
- **GitOps Reconciler** (`monitor`) — agent of record for declarative fleet-state reconciliation: `System::Gitops::Reconciler` diffs a registered `System::GitopsRepository`'s desired state against live state and authors the drift proposals under this agent (previously attributed to an arbitrary first account agent). Owns the operator-initiated `system.gitops_*` actions (apply proposal / register repository / sync). The **autonomous** `system.gitops_drift_remediate` policy lives on **Fleet Autonomy** (its `GitopsDriftSensor` runs in `FleetAutonomyService::SENSORS`, which gates as Fleet Autonomy — same split as the autonomous `system.sdwan_*` remediations). Trust tier: monitored. Seeded by `db/seeds/system_gitops_reconciler_agent.rb`.

## Concierge-Driven Provisioning

Operators run infrastructure provisioning by talking to the **System Concierge**
in chat. A natural-language request becomes an approval-gated `Ai::Mission`
(`mission_type: "infrastructure"`) bound to the `system_provisioning` template
([`db/seeds/system_provisioning_mission_template.rb`](./server/db/seeds/system_provisioning_mission_template.rb)).

- Operator guide: [`docs/CONCIERGE_PROVISIONING_GUIDE.md`](./docs/CONCIERGE_PROVISIONING_GUIDE.md) — how to ask the Concierge to provision, the phase pipeline, the inline Approve/Reject card, and how to monitor progress.
- Architecture: [`docs/MISSION_COMPOSITION_ARCHITECTURE.md`](./docs/MISSION_COMPOSITION_ARCHITECTURE.md) — the two composition paths, hybrid routing, cross-step data flow, and how both converge on one runner + approval gate.

**Orchestration spine** (all core services in the parent `server/` tree; the
extension supplies the executors, the mission template, and the Concierge):

```
Concierge NL → ConciergeToolBridge.classify_and_dispatch_provisioning (intent + confidence ≥ 0.5)
  → ProvisioningTool capture_brief (IntentCaptureService → mission.configuration["brief"])
  → HYBRID ROUTING:
       recognized provisioning scenario → PlanComposerService  (deterministic, ALLOWED_EXECUTORS)
       novel intent                     → MissionComposer       (LLM-general, any agent-bound skill)
     both → Ai::GoalPlan of provisioning_skill steps + mission.configuration["plan"]["plan_id"]
  → review_plan gate (inline Approve card → OrchestratorService#handle_approval! → advance!)
  → AiProvisioningExecuteJob → SkillCompositionRunner (topological layers, per-step AiProvisioningStepJob,
       depends_on_outputs resolved from predecessor metadata.last_outputs, broadcast_step_event!)
  → verify → handoff gate → RalphLoop → adapting (sensor-driven)
```

Phases (`capture_intent → compose_plan → review_plan → execute → verify → handoff
→ adapting`) and the two approval gates (`review_plan`/`plan_review`, `handoff`)
are defined on the template. Execution is reached **only** by approving
`review_plan` — there is no separate execute action (it raced and
double-provisioned).

## MCP Tools

System-extension MCP actions follow these prefixes:

- `system_*` — fleet ops, modules, instances, templates, tasks, container runtime provisioning, disk image CI
- `system_sdwan_*` — SDWAN management (~73 actions)
- `kubernetes_*` — Phase 2 K8s clusters (read + decommission + kubeconfig)
- `docker_*` — DockerHost CRUD + container/image/network/volume management (works on managed + external hosts)

The full action catalog regenerates via `cd server && bundle exec rails mcp:generate_tool_catalog` (from the **parent platform** tree, auto-generated at `docs/reference/auto/mcp-tools.md` in that tree — the extension does not contain its own copy). For an operator-curated subset see [`docs/MCP_API_REFERENCE.md`](./docs/MCP_API_REFERENCE.md).

## Critical Conventions

### When adding a new capability

1. Always check existing skill executors before writing a new orchestration. 53 already cover most fleet/SDWAN/runtime/topology workflows. See `docs/SKILL_EXECUTORS.md`.
2. New skills must have BOTH an executor at `app/services/system/ai/skills/<name>_executor.rb` AND an `Ai::Skill` record (seeded via `db/seeds/system_skills_seed.rb`).
3. New autonomy actions must have a `system.<action>` intervention policy entry in either `fleet_autonomy_agent.rb` or `system_runtime_manager_agent.rb`.
4. Cross-account safety: use `find_or_create_by` with `account: account` scoping. The KG seeds + skill seeds follow this pattern.

### Submodule mechanics

This is a git submodule. Per root CLAUDE.md:
- Always run `git rev-parse --show-toplevel` before `git add`/`commit`
- Commit inside the submodule first, then bump the parent's submodule pointer
- The system extension is dual-remoted: `origin` = private Gitea upstream (`git@git.powernode.net:powernode/powernode-system.git`), `github` = public GitHub mirror (MIT, `github.com/nodealchemy/powernode-system`). Push to **both** on every push to a shared branch (e.g. `develop`) — keep the public mirror continuously in sync. Do **not** run `git submodule sync`: `.gitmodules` records the public **HTTPS** GitHub URL, so sync overwrites `origin`'s Gitea URL with it — losing the private upstream, and leaving an origin that cannot push non-interactively (`could not read Username for 'https://github.com'`).

### Test patterns

- RSpec specs under `server/spec/`
- Live smoke tests under `server/db/seeds/smoke_test_*.rb` — run via `cd server && rails runner "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_<name>.rb')"`
- Go agent tests under `agent/internal/*/` — run via `cd agent && go test ./...`

## Related Docs

### Reference

- `README.md` — extension overview
- `CONTRIBUTING.md` — submodule + commit workflow
- `docs/ARCHITECTURE.md` — 9 subsystems + 4 API surfaces + security architecture
- `docs/SDWAN_ARCHITECTURE.md` — SDWAN compile pipeline: intent models → orchestrator (`Sdwan::TopologyCompiler`) + per-stage compilers (BGP/FRR, OVN, nftables firewall/NAT) → on-node artifacts, allocators, topology strategies, MCP surface
- `docs/PROVIDER_ADAPTER_AUTHORING.md` — how to write a new cloud/hypervisor provider adapter (the `System::Providers::BaseProvider` 24-method contract, normalized return shapes, credential resolution, Registry wiring, and the `it_behaves_like "a cloud provider"` shared spec)
- `docs/STORAGE_SUBSYSTEM.md` — storage data plane: volumes, mounts, chown ownership model, volume-to-volume migration state machine + MCP surface
- `docs/SMOKE_TEST.md` — platform-level smoke catalog (18 seeded scripts, 8 passes: boot, container runtimes, SDWAN, federation, ACME, storage, credentials, hardware/CI extras)
- `docs/CONTAINER_RUNTIMES.md` — Phase 1 Docker + Phase 2 K3s operator guide + troubleshooting
- `docs/CLAUDE_TMUX_MODULE.md` — claude-tmux NodeModule: managed Claude Code CLI in a systemd-supervised tmux session, Vault-backed credential injection at boot, operator runbook
- `docs/USE_CASE_MATRIX.md` — what works / what doesn't / what to expect for 10 NodeInstance container use cases (READ FIRST when designing a deployment)
- `docs/SKILL_EXECUTORS.md` — 53 executor reference; `docs/SKILL_EXECUTOR_CATALOG.md` is the auto-generated catalog (regenerate via `rails system:skills:generate_catalog` — never hand-edit)
- `docs/CONCIERGE_PROVISIONING_GUIDE.md` — operator guide for running a provisioning mission through the System Concierge (phase pipeline, inline approval card, monitoring)
- `docs/INGRESS_TLS_GUIDE.md` — operator guide for ingress/TLS (Ingress page Routes + Expose-Service wizard, the VIP→port-map→ACME→Traefik expose lifecycle, DNS-01 credentials, staging-vs-prod issuers, split-brain DNS troubleshooting)
- `docs/MISSION_COMPOSITION_ARCHITECTURE.md` — two composition paths (deterministic vs. LLM-general), hybrid routing, cross-step data flow, and the shared runner + approval gate
- `docs/FLEET_SENSORS.md` — 24 fleet sensors (tick-registered) + 2 CVE sensors reference + intervention policy table (split per-agent post 2026-05-10)
- `docs/DISK_IMAGE_CI.md` — webhook + CI worker workflow
- `docs/MCP_API_REFERENCE.md` — `system_*` / `system_sdwan_*` / `kubernetes_*` / `docker_*` MCP tool actions
- `docs/agent-peering.md` — NodeInstance-as-Agent pattern
- `docs/credential-restoration.md` — Vault credential lifecycle
- `docs/gitops.md` — GitOps reconciler design
- `initramfs/README.md` — multi-arch boot builder

### Operator runbooks (`docs/runbooks/`)

See `docs/runbooks/README.md` for the full index (audience + prereqs + runtime per runbook). Current set:

- `node-provisioning.md` — full Node + NodeInstance lifecycle with per-state error recovery
- `fleet-imaging-claim-by-id.md` — bulk-provision physical devices from one generic image + a per-device claim-by-ID `identity.cfg`
- `sdwan-network-setup.md` — SDWAN end-to-end (networks, peers, VIPs, firewall, BGP, federation)
- `module-authoring.md` — author + register + sign + publish a new NodeModule
- `cve-response.md` — full CVE response workflow (SBOM-aware matching, triage, remediation)
- `gitops-reconciliation.md` — operator GitOps reconciler workflow (Phase A4)
- `acme-issuance.md` — ACME DNS-01 cert lifecycle (Phase A4)
- `acme-smoke.md` — P2.5.7 acceptance smoke test
- `expose-service.md` — publish a service publicly with TLS (VIP → port map → ACME → Traefik expose lifecycle)
- `publish-service.md` — publish a service locally at `/svc/<slug>` to your own authenticated users (Sdwan::Service local plane + ForwardAuth)
- `instance-pool-tuning.md` — pool sizing + reaping (slice 7)
- `multi-cluster-k3s.md` — multi-cluster K3s with `metadata.target_cluster_id` + HA control plane
- `disk-image-ci.md` — disk image CI operator workflow
- `federation-setup.md` — multi-region/multi-account federation peering
- `federation-troubleshooting.md` — diagnostic procedures for federation failures
- `vault-credential-restoration.md` — DR runbook for credential restoration
- `storage-migration.md` — volume-to-volume data migration end-to-end (plan→approve→sync→cutover) + chown status/retry + NFS probe

### Tutorials (`docs/tutorials/`) — preferred entry point for learning

13 numbered, dependency-aware tutorials covering the full operator surface:

- `01-first-boot.md` — single-node QEMU boot end-to-end
- `02-first-module.md` — author + sign + publish a custom module
- `03-docker-runtime.md` — Phase 1 Docker daemon provisioning
- `04-k3s-cluster.md` — Phase 2 K3s cluster with VIP-backed api_endpoint
- `05-multi-cluster-k3s.md` — multi-cluster + SDWAN isolation
- `06-rolling-upgrade.md` — batched module upgrades with circuit breaker
- `07-cve-response.md` — full CVE response pipeline (drill)
- `08-instance-pool.md` — pre-warmed pools for bursty workloads
- `09-honeypot-canary.md` — decoy assets + intervention policy
- `10-gitops-fleet.md` — fleet.yaml declarative state + reconciler
- `11-federation.md` — multi-region federation, spawn modes, P9.x guarantees
- `12-disk-image-ci.md` — custom NodePlatform via CI-published OCI artifacts
- `13-expose-service-tls.md` — expose a service publicly with TLS (VIP + port map + ACME + Traefik)

Start with `docs/tutorials/INDEX.md` for a Mermaid decision tree mapping operator goal → starting tutorial.
