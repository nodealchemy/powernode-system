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
| Skill executors | `docs/SKILL_EXECUTORS.md` | `app/services/system/ai/skills/` (65 executor classes, 64 with `binds_to`), `db/seeds/system_skills_seed.rb` + `db/seeds/system_provisioning_skills_seed.rb` + `db/seeds/system_dr_skills_seed.rb` (ALL THREE seed `Ai::Skill` rows — check all three before adding one; a slug must live in exactly ONE of them, since they all upsert by slug and the later file in `SYSTEM_SEED_FILES` silently wins) |
| Disk image CI | `docs/DISK_IMAGE_CI.md` | `app/models/system/{disk_image_publication,disk_image_webhook}.rb`, `app/services/system/disk_image_*_service.rb` |
| CI workers + Gitea Actions | (cross-cuts disk image CI) | `app/services/system/{worker_dispatch,execution_dispatcher}.rb` |
| Tasks + autonomy reconcile | `docs/ARCHITECTURE.md` §4 | `app/models/system/task.rb`, `app/services/system/execution_dispatcher.rb` |
| Honeypot canaries | `docs/ARCHITECTURE.md` §7 | `app/services/system/honeypot/canary_module_service.rb` |
| Storage (volumes, mounts, migration, chown) | `docs/STORAGE_SUBSYSTEM.md`, `docs/runbooks/storage-migration.md` | `app/models/system/{provider_volume,storage_assignment,storage_migration,storage_credential}.rb`, `app/services/system/storage/`, `app/services/ai/tools/{system_fleet_tool,system_storage_owner_tool}.rb` |

## AI Agents (12)

The system extension declares twelve official AI agents with distinct trust scores + approval chains, all twelve seeded (`db/seeds/*_agent.rb`, each through `AgentSetupHelpers.find_or_initialize_global_agent`) and declared in `System::Governance::PolicyDeclarations::AGENT_IDENTITIES`; HIER-P2DECL declared the four operations managers in wave 1 and HIER-P2B/P2C/P2D/P2E seeded them in wave 2. The 2026-05-10 split brought Concierge + Fleet Autonomy + Runtime Manager + CVE Responder + SDWAN Manager + Disk Image Manager — replacing an earlier 3-agent model where Fleet Autonomy owned CVE, SDWAN, and Disk Image work. Phase O6 then added System Topology Designer as the first specialist in the cross-cutting design track, and the GitOps Reconciler closed the declarative-reconciliation gap (proposals previously attributed to an arbitrary agent). HIER-P2DECL (2026-09-03, Phase 2 wave 1) split Fleet Autonomy's capacity, storage, ingress and supply-chain policy groups onto a Capacity Manager, a Storage Manager, an Ingress Manager and a Supply Chain Manager, gave the Topology Designer the topology set, and paired every operator-only policy set with an agent twin; all twelve hang under the System Concierge (HIER-P1). Each domain has its own queue so operators can pause one (e.g. SDWAN during maintenance) without halting the others. Note: Fleet Autonomy's seed file is `db/seeds/fleet_autonomy_agent.rb` (no `system_` prefix — predates the naming convention); the others follow `db/seeds/system_<name>_agent.rb`.

- **System Concierge** (`assistant`, chat) — operator chat agent. `concierge_tool_filter` covers `system_*`, `docker_*`, `kubernetes_*`, plus `discover_skills`/`get_skill_context`/`request_confirmation`. **25 skills bound**: 12 read-shape, 12 state-changing (incl. `system-fulfill-capability-request`, the end-to-end "purpose → node" path), plus the executor-less `system-provision-infrastructure` front door. The full split lives in the seeded prompt — `db/seeds/system_concierge_agent.rb` is the source of truth; do not re-list it here, it drifts.
- **Fleet Autonomy** (`monitor`) — the node-lifecycle / remediation core, running every 60s: cert rotation, drift remediation, module composition, rolling upgrades, the investigate lanes. 9 skills bound (HIER-P2SWEEP re-bound `attach_storage` to the Capacity Manager; the nine that stay are `promote_replica`, `rolling_module_upgrade`, `boot_image_drift_rollout`, `fulfill_capability_request` — whose action categories are in `FLEET_AUTONOMY_POLICIES` — plus the five that declare no `action_category`: `module_smoke_verify`, `module_compose`, `deploy_app_code`, `drift_remediate`, `discover_packages_by_intent`). 19 intervention policies (after the 2026-05-10 split moved CVE → CVE Responder, operator SDWAN CRUD → SDWAN Manager, and Disk Image → Disk Image Manager; HIER-P2A moved the 14 autonomous `system.sdwan_*` / `system.federation_*` remediations → SDWAN Manager, `system.gitops_drift_remediate` → GitOps Reconciler and `system.disk_image_publication_investigate` → Disk Image Manager; and HIER-P2DECL moved 35 more — the capacity, instance-pool and provisioning keys → Capacity Manager, storage → Storage Manager, ingress + `system.service_backends_update` → Ingress Manager, packages + architecture → Supply Chain Manager, the two composer keys → System Topology Designer. Every sensor still RUNS on this agent's tick, but each `SIGNAL_BINDINGS` entry is gated under its declared `owner:`, and a declared owner that is not seeded yet falls back to this agent with a `fleet.owner_agent_missing` event) — see [`docs/FLEET_SENSORS.md`](./docs/FLEET_SENSORS.md) §Intervention Policy Reference). Seeded by `db/seeds/fleet_autonomy_agent.rb`.
- **Capacity Manager** (`monitor`) — the capacity keeper: desired vs live replicas, the DR replace/reap pair, region expansion, capacity resize, workload relocation, the eight instance-pool verbs, the six `project.*` provisioning / adaptation verbs, platform scale-out/in and the cordon. 7 skills bound (`replace_instance`, `reap_instance`, `relocate_workload`, `scale_project`, `provision_full_stack` re-bound from Fleet Autonomy in HIER-P2B, `attach_storage` re-bound from Fleet Autonomy in HIER-P2SWEEP — it runs during subdomain provisioning, and the Storage Manager owns the volume plane rather than the provisioning step; `platform_resilience` shared with the Concierge). 22 intervention policies (`CAPACITY_MANAGER_POLICIES`; twin of the instance-pool, platform-scaling and cordon operator sets). Sensor-routed here: `instance_unrecoverable_sensor` and the three `project_*` kinds (plus `System::AdaptationGate`). Distinct approval chain (`Capacity Manager Actions`, 4h, reject on timeout). `tool_access.tool_families` scoped to instances, pools, node/template reads, platform scaling, provisioning, task and storage reads. Seeded by `db/seeds/system_capacity_manager_agent.rb` (HIER-P2B). Operator guide: [`docs/CAPACITY_MANAGER_AGENT.md`](./docs/CAPACITY_MANAGER_AGENT.md).
- **Storage Manager** (`monitor`) — the storage data plane's autonomy surface: storage assignment reconciliation, volume restore (copy-swap semantics), snapshot delete, migrations, chown, NFS export probes. 1 skill bound (`restore_volume`, re-bound from Fleet Autonomy). 3 intervention policies (`STORAGE_MANAGER_POLICIES`; twin of the volume-snapshot operator set). Sensor-routed here: `storage_assignment_drift_sensor`. Distinct approval chain (`Storage Manager Actions`, 8h, reject on timeout). `tool_access.tool_families` scoped to the storage MCP verbs + instance reads, which HIER-P1B turns into the Claude Code `tools:` allowlist. Seeded by `db/seeds/system_storage_manager_agent.rb` (HIER-P2C). Operator guide: [`docs/STORAGE_MANAGER_AGENT.md`](./docs/STORAGE_MANAGER_AGENT.md).
- **Ingress Manager** (`monitor`) — service exposure and certificate issuance: the `/svc/<slug>` local publish, public TCP / HTTPS exposure, ACME DNS-01 issuance and a published service's backend set. 4 skills bound (`expose_service_local`, `expose_service_publicly`, `expose_service_public_tcp`, `acme_certificate_provision` — each shared with the Concierge for operator chat; the ACME one left Fleet Autonomy). 5 intervention policies (`INGRESS_MANAGER_POLICIES`: the four executor gates plus `system.service_backends_update`); no sensor routes to it — every row gates an executor / MCP door; `system.acme_cert_rotate` (renewal) stays Fleet Autonomy's. Distinct approval chain (`Ingress Manager Actions`, 4h, reject on timeout). `tool_access.tool_families` scoped to services, expose/unexpose, ACME, VIP reads and the reverse-proxy compose. Seeded by `db/seeds/system_ingress_manager_agent.rb` (HIER-P2D). Operator guide: [`docs/INGRESS_MANAGER_AGENT.md`](./docs/INGRESS_MANAGER_AGENT.md).
- **Supply Chain Manager** (`monitor`) — the software-supply-chain custodian: package repository sync, package-derived module creation / refresh and the shared architecture catalog. 8 skills bound (`package_repository_sync`, `package_module_create`, `package_module_refresh`, the four `architecture_*` executors and `suggest_architectures_for_fleet`, all re-bound from Fleet Autonomy; `package_module_refresh` stays on the CVE Responder too — `CveRemediationOrchestrationExecutor` invokes it directly). 7 intervention policies (`SUPPLY_CHAIN_MANAGER_POLICIES`; every new package is operator-audited — `system.package_module.create` is `require_approval`, sync is `auto_approve`). The seed writes NO policy row: the set moved off Fleet Autonomy, so `PolicyReconciler` creates it on a fresh install and re-homes an established install's tuned rows in place. Sensor-routed here: `package_drift_sensor`. Distinct approval chain (`Supply Chain Manager Actions`, 8h, reject on timeout). `tool_access.tool_families` scoped to package repositories / packages / package modules, architectures, module reads and CVE reads. Seeded by `db/seeds/system_supply_chain_manager_agent.rb` (HIER-P2E). Operator guide: [`docs/SUPPLY_CHAIN_MANAGER_AGENT.md`](./docs/SUPPLY_CHAIN_MANAGER_AGENT.md).
- **Runtime Manager** (`monitor`) — Phase 1 Docker + Phase 2 K3s lifecycle. 2 skills bound (`docker_provision`, `provision_cluster`). 7 intervention policies (the `system.runtime_docker_tls_rotate` policy was removed during the 2026-05-19 audit — no executor existed; operators rotate Docker daemon TLS via the broader `system.cert_rotate` flow). Distinct approval chain so container runtime changes route separately. Seeded by `db/seeds/system_runtime_manager_agent.rb`.
- **CVE Responder** (`monitor`) — security-focused reconciler running every 60s via `SystemCveResponderReconcileJob`. Owns the full chain: CVE ingest (via hourly `SystemCveFeedJob`) → exposure scan → triage → critical-upgrade detection → orchestrated rebuild + rolling upgrade. 5 skills bound (`cve_response`, `cve_remediation_orchestration`, `cve_runbook_generate`, `rolling_module_upgrade`, `package_module_refresh`). 5 intervention policies. 8h approval timeout (security responses span business days). Seeded by `db/seeds/system_cve_responder_agent.rb`. Sensors live in `app/services/system/cve_ops/sensors/`: `CvePublishedSensor` emits `system.cve_critical_published` for fresh critical/high exposures; `CriticalUpgradeAvailableSensor` emits `system.module_critical_upgrade_ready` only when drift AND open CveExposure intersect (the "patch already exists, fly it" path which gets `notify_and_proceed`).
- **SDWAN Manager** (`monitor`) — owns SDWAN peer drift, hub reachability, BGP session health, VIP failover, and operator-initiated SDWAN CRUD. 57 intervention policies (43 operator `sdwan.*` CRUD, also seeded at the operator shape, + 14 sensor-routed `system.sdwan_*` / `system.federation_*` remediations gated here since HIER-P2A); 4h approval timeout. Skills bound: `sdwan_*` reconciliation executors. Seeded by `db/seeds/system_sdwan_manager_agent.rb` (2026-05-10). Operator guide: [`docs/SDWAN_MANAGER_AGENT.md`](./docs/SDWAN_MANAGER_AGENT.md).
- **Disk Image Manager** (`monitor`) — owns disk image CI publication lifecycle (build → verify → promote → retention). 3 skills bound (`disk_image_promote`, `disk_image_rollback`, `disk_image_retention` — HIER-P2F, thin over the `Executors::DiskImage` services, each gated on the agent's own row). 7 intervention policies (6 operator-initiated + the sensor-routed `system.disk_image_publication_investigate`, gated here since HIER-P2A); 12h approval timeout; 5-minute tick. `tool_access.tool_families` scoped to the five disk-image MCP verbs. Seeded by `db/seeds/system_disk_image_manager_agent.rb` (2026-05-10). Operator guide: [`docs/DISK_IMAGE_MANAGER_AGENT.md`](./docs/DISK_IMAGE_MANAGER_AGENT.md). For the upstream CI pipeline see [`docs/DISK_IMAGE_CI.md`](./docs/DISK_IMAGE_CI.md).
- **System Topology Designer** (`assistant`) — specialist agent for cross-cutting platform topology design (Phase O6, first specialist in the cross-cutting design track). Charter: SDWAN composition today (host bridges, OVN logical networks, IPFIX collectors); container networking + storage topology in future. Invoked by Concierge via `execute_agent` for topology composition. 8 skills bound: the 5 SDWAN compose skills (`system-sdwan-host-bridge-compose`, `system-sdwan-ovn-compose-topology`, `system-sdwan-ipfix-collector-compose`, `system-sdwan-compose-full-topology`, `system-sdwan-ovn-apply-acl`) plus the three composer gates `system-sdwan-federation-compose`, `system-multi-tenant-isolation`, `system-service-discovery-composer` (bound via `binds_to "topology_designer"` since HIER-P2F). 3 intervention policies since HIER-P2DECL (`TOPOLOGY_DESIGNER_POLICIES`: the three composer executor gates, `system.sdwan_federation_compose` declared for the first time; none sensor-routed; the seed consumes the set since HIER-P2F and `PolicyReconciler` asserts it on every later boot). Distinct approval chain (`Topology Designer Actions`, 8h, reject on timeout). `tool_access.tool_families` scoped to the `system_sdwan` surface, the two other composer verbs, K8s/Docker topology reads and skill discovery. Trust tier: monitored. Seeded by `db/seeds/system_topology_designer_agent.rb`.
- **GitOps Reconciler** (`monitor`) — agent of record for declarative fleet-state reconciliation: `System::Gitops::Reconciler` diffs a registered `System::GitopsRepository`'s desired state against live state and authors the drift proposals under this agent (previously attributed to an arbitrary first account agent). Owns the operator-initiated `system.gitops_*` actions (apply proposal / register repository / sync) and, since HIER-P2A, the **autonomous** `system.gitops_drift_remediate` policy too: its `GitopsDriftSensor` still runs in `FleetAutonomyService::SENSORS`, but the binding declares `owner: "gitops-reconciler"` and the tick gates it under this agent. 3 skills bound (`gitops_sync_repository`, `gitops_apply_proposal`, `gitops_register_repository` — HIER-P2F, thin over `Gitops::Reconciler` / `Gitops::ApplyService`, gated on the same three operator rows the MCP verbs use). 4 intervention policies. `tool_access.tool_families` = the `system_gitops` family. Trust tier: monitored. Seeded by `db/seeds/system_gitops_reconciler_agent.rb`.

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

1. Always check existing skill executors before writing a new orchestration. 64 already cover most fleet/SDWAN/runtime/topology workflows. See `docs/SKILL_EXECUTORS.md`.
2. New skills must have BOTH an executor at `app/services/system/ai/skills/<name>_executor.rb` AND an `Ai::Skill` record (seeded via one of the three skills seeds — see the Skill executors row above). Without the row, `SkillBindings.validate!` raises unrescued and zeroes every `Ai::AgentSkill`.
3. New autonomy actions must have a `system.<action>` intervention policy declared in `System::Governance::PolicyDeclarations`, in the set of the agent that OWNS the category (the seeds consume those constants; `PolicyReconciler` creates missing rows on every boot and re-homes rows whose owner moved — record a move in `PolicyReconciler::FORMER_OWNERS`). A sensor-routed category also declares that agent as `owner:` on its `DecisionEngine::SIGNAL_BINDINGS` entry — `sensor_owner_gating_spec` pins that the two agree. An operator-only set gets an agent twin (`PolicyDeclarations::OPERATOR_TWINS`).
4. Cross-account safety: account-owned rows use `find_or_create_by` with `account: account` scoping (the KG seeds follow this). Official agents AND skills are GLOBAL seeded canonicals (`account_id NULL`, `source_key`, `is_system`; `find_or_initialize_global_agent` / `db/seeds/concerns/skill_setup_helpers.rb`) — an account customises one by cloning it, never by a second account-scoped row of the same key (HIER-P1 / HIER-P2G).

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
- `docs/SMOKE_TEST.md` — platform-level smoke catalog covering boot, container runtimes, SDWAN, federation, ACME, storage, credentials, hardware/CI, and K3s. The catalog is the source of truth for seed-script and pass counts — they are deliberately not restated here (they drift; see the hygiene spec at `server/spec/integration/claude_md_smoke_catalog_reference_spec.rb`)
- `docs/CONTAINER_RUNTIMES.md` — Phase 1 Docker + Phase 2 K3s operator guide + troubleshooting
- `docs/CLAUDE_TMUX_MODULE.md` — claude-tmux NodeModule: managed Claude Code CLI in a systemd-supervised tmux session, Vault-backed credential injection at boot, operator runbook
- `docs/GROK_CLI_MODULE.md` — grok-cli NodeModule: xAI's Grok Build CLI on PATH plus a Vault-backed boot-time key fetch; sibling of claude-tmux, deliberately WITHOUT a supervised session (an always-on agent spends money while idle). Also documents the provider-general `config/ai_cli_credential` node_api endpoint and the per-provider account-fallback SiteSettings
- `docs/USE_CASE_MATRIX.md` — what works / what doesn't / what to expect for 10 NodeInstance container use cases (READ FIRST when designing a deployment)
- `docs/SKILL_EXECUTORS.md` — 64 executor reference; `docs/SKILL_EXECUTOR_CATALOG.md` is the auto-generated catalog (regenerate via `rails system:skills:generate_catalog` — never hand-edit)
- `docs/CONCIERGE_PROVISIONING_GUIDE.md` — operator guide for running a provisioning mission through the System Concierge (phase pipeline, inline approval card, monitoring)
- `docs/INGRESS_TLS_GUIDE.md` — operator guide for ingress/TLS (Ingress page Routes + Expose-Service wizard, the VIP→port-map→ACME→Traefik expose lifecycle, DNS-01 credentials, staging-vs-prod issuers, split-brain DNS troubleshooting)
- `docs/MISSION_COMPOSITION_ARCHITECTURE.md` — two composition paths (deterministic vs. LLM-general), hybrid routing, cross-step data flow, and the shared runner + approval gate
- `docs/FLEET_SENSORS.md` — 34 fleet sensors (tick-registered) + 2 CVE sensors reference + intervention policy table (split per-agent post 2026-05-10)
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
- `multi-cluster-k3s.md` — multi-cluster K3s bootstrap (an HA control plane, Phase 4, is NOT IMPLEMENTED — a second `k3s-server` bootstraps a separate cluster). Adding workers to a *chosen* cluster (Phase 3) is NOT IMPLEMENTED: `target_cluster_id` is wired on the platform side and unreachable from the agent, so k3s-agent joins are refused once a second cluster exists
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
- `06-rolling-upgrade.md` — module upgrade plans (the batched runtime + circuit breaker are NOT IMPLEMENTED) + the manual procedure that works
- `07-cve-response.md` — full CVE response pipeline (drill)
- `08-instance-pool.md` — pre-warmed pools for bursty workloads
- `09-honeypot-canary.md` — decoy assets + intervention policy
- `10-gitops-fleet.md` — fleet.yaml declarative state + reconciler
- `11-federation.md` — multi-region federation, spawn modes, P9.x guarantees
- `12-disk-image-ci.md` — custom NodePlatform via CI-published OCI artifacts
- `13-expose-service-tls.md` — expose a service publicly with TLS (VIP + port map + ACME + Traefik)

Start with `docs/tutorials/INDEX.md` for a Mermaid decision tree mapping operator goal → starting tutorial.
