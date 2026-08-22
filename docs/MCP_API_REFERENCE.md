# MCP API Reference

> Status: active

Action catalog for the system extension's MCP surface. Lists every `system_*`, `system_sdwan_*`, `kubernetes_*`, and `docker_*` action callable via the Powernode MCP server.

**Audience:** AI Concierge prompt authors, external operators integrating with the platform's MCP server, contributors adding new actions.

## Where actions are registered (architecture note)

> **Architecture:** The MCP **registry** (action-name → tool-class mapping) lives in the **parent platform** at `server/app/services/ai/tools/platform_api_tool_registry.rb`. The **tool class implementations** live in the **extension** at `extensions/system/server/app/services/ai/tools/`. Rails autoloading resolves the class names across both locations.

```mermaid
flowchart LR
    subgraph Parent["Parent platform"]
        Reg["platform_api_tool_registry.rb"]
        M1["system_* → Ai::Tools::SystemFleetTool"]
        M2["system_sdwan_* → Ai::Tools::SdwanTool"]
        M3["kubernetes_* → Ai::Tools::Kubernetes*Tool"]
        M4["docker_* → Ai::Tools::Docker*Tool"]
        Reg --- M1
        Reg --- M2
        Reg --- M3
        Reg --- M4
    end

    subgraph Ext["System extension"]
        T1[system_fleet_tool.rb]
        T2[sdwan_tool.rb]
        T3[kubernetes_*_tool.rb]
        T4[docker_*_tool.rb]
        Svc[/services/system/<br/>*_service.rb<br/>lifecycle + biz logic/]
        T1 --> Svc
        T2 --> Svc
        T3 --> Svc
        T4 --> Svc
    end

    MCP[(MCP client<br/>call to action)] --> Reg
    M1 -. "class-name string<br/>resolved by autoloader" .-> T1
    M2 -.-> T2
    M3 -.-> T3
    M4 -.-> T4
```

To add a new MCP action: register the action-name → class-name mapping in the **parent's** registry file, then implement the action method in the corresponding tool class **inside the extension**. Both repos commit; bump the submodule pointer.

To regenerate the parent's full tool catalog with parameter schemas:

```bash
cd server && bundle exec rails mcp:generate_tool_catalog
# → writes to docs/platform/MCP_TOOL_CATALOG.md (gitignored)
```

This document is the **system-extension subset** of that catalog — manually curated, scannable for operator workflows.

## Permission model

Every action requires a permission grant on the calling user/agent. Permissions follow the schema `<resource>.<verb>` (e.g., `system.nodes.read`, `system.modules.write`). The mapping lives in `server/db/migrate/*_permissions.rb` (parent platform). Agents have permissions assigned via `Ai::AgentPermission`.

## Action catalog

### `system_*` — Fleet, lifecycle, modules, storage, architecture, GitOps, CI workers, disk image CI, providers, topology, ingress, GPU/inference, agent-fleet, A2A (128 actions)

Backed by `Ai::Tools::SystemFleetTool` (parent-registered, extension-implemented) plus the managed-Docker, package-repository, architecture-catalog, disk-image, ingress, storage-owner, and agent-fleet tool classes. The registry routing lives in the parent (`platform_api_tool_registry.rb`); the tool-class implementations live in the extension under `server/app/services/ai/tools/`.

#### Nodes + instances

| Action | What it does | Audience |
|---|---|---|
| `system_list_nodes` | List Node rows (filter by status, lifecycle_class, etc.) | operator, agent |
| `system_get_node` | Fetch a Node by id | operator, agent |
| `system_create_node` | Create a Node row (no provider VM yet) | operator, agent |
| `system_list_instances` | List NodeInstance rows | operator, agent |
| `system_get_instance` | Fetch NodeInstance details (status, last_heartbeat, running modules) | operator, agent |
| `system_provision_instance` | Trigger provider VM creation; creates Task; returns NodeInstance | operator, agent |
| `system_terminate_instance` | Destroy provider VM; cascade-FK cleanup | operator, agent |
| `system_drift_report` | Compare running module digests vs assigned modules | operator, agent |

#### Templates + modules

| Action | What it does |
|---|---|
| `system_list_templates` | List NodeTemplates |
| `system_get_template` | Fetch a Template + its module assignments |
| `system_update_template` | Edit any field `system_create_template` accepts: name, description, enabled, public, node_platform_id, admin_user, config (`config` replaces the stored hash) |
| `system_assign_module_to_template` | Add a module to a Template, with the join's own `priority`, `enabled`, `config` (e.g. `target_cluster_id`) and `recommends_override`. Refuses error-severity composition conflicts; `enabled: false` stages the assignment without shipping it and skips the conflict check |
| `system_update_template_module` | Edit an existing assignment in place (priority/enabled/config/recommends_override). **`enabled: false` is the correct way to remove a module** — unassigning destroys the join, which nullifies `source_template_module_id` on every derived NodeModuleAssignment and orphans them permanently. Re-enabling runs the conflict check |
| `system_list_modules` | List NodeModules |
| `system_get_module` | Fetch a Module + its categories + dependencies |
| `system_list_module_versions` | List versions of a module |
| `system_promote_module_version` | Move a version through lifecycle states (built → staging → blessed → live) |
| `system_validate_module_manifest` | Dry-run validation of a `manifest.yaml` payload against the manifest schema before publishing |

#### Tasks

| Action | What it does |
|---|---|
| `system_list_tasks` | List Tasks (filter by status, type) |
| `system_cancel_task` | Cancel a pending or in-flight Task |

#### Instance pools (slice 7)

| Action | What it does |
|---|---|
| `system_list_instance_pools` | List InstancePools |
| `system_get_instance_pool` | Fetch a pool + its members |
| `system_create_instance_pool` | Create a new pool (target_size, min, max, region, type, template) |
| `system_drain_instance_pool` | Stop replenishing + destroy/release members |
| `system_delete_instance_pool` | Remove a drained pool (refuses while members are still attached) |
| `system_acquire_pooled_instance` | Atomic claim of a `ready` member |
| `system_return_pooled_instance` | Return a claimed member to the pool (reaper resets state) |
| `system_replenish_instance_pool` | Manual trigger of the reaper for this pool |

#### Container runtimes

| Action | What it does |
|---|---|
| `system_provision_docker_runtime` | Phase 1 Docker daemon provisioning on a NodeInstance |
| `system_decommission_docker_runtime` | Destroy managed DockerHost row + Vault TLS material |
| `system_mark_docker_ready` | Agent-side ack endpoint (mostly internal) |
| `system_list_managed_docker_hosts` | List Powernode-managed Docker hosts (excludes externally-registered) |

#### Package repositories + catalog

Backed by `Ai::Tools::SystemPackageRepositoryTool`. Manages apt/rpm package repositories, browses the synced catalog with rich filtering, and materializes packages into NodeModules with full dependency closure.

| Action | What it does | Audience |
|---|---|---|
| `system_list_package_repositories` | List accessible apt/rpm repositories (account-scoped + shared); filter by `kind` and `node_platform_ids[]`. Each row carries `embedding_pending_count` for catalog coverage. | operator, agent |
| `system_get_package_repository` | Fetch one repository with detail (apt_config, rpm_config, linked NodePlatforms) | operator, agent |
| `system_create_package_repository` | Register a new apt/rpm/dnf repository (`visibility: shared` requires `system.package_repositories.manage_shared`) | operator |
| `system_update_package_repository` | Update repository config (architectures, enabled, priority, apt/rpm config) | operator |
| `system_delete_package_repository` | Delete a repository (only when no modules link to its packages) | operator |
| `system_sync_package_repository` | Trigger an immediate upstream sync (fetches index, upserts Package rows). Enqueues `SystemPackageEmbeddingJob` after successful sync. | operator, agent |
| `system_link_repository_platform` / `system_unlink_repository_platform` | M:N link/unlink between repository and NodePlatform | operator |
| **`system_search_packages`** | **Search the synced catalog. Hybrid trigram+embedding ranking (default), pure lexical, or pure semantic.** Filters: `q`, `mode` (lexical/semantic/hybrid), `repository_ids[]`, `kind`, `architectures[]` (canonical, cross-kind expanded), `sections[]`, `license`, `provides` (capability lookup), `sort`, `page`, `per_page`. Back-compat with singular `repository_id`/`architecture`/`section`. Response includes `similarity` (when mode ≠ lexical), `provides_names`, `license`, `applied_filters` echo. `total` is null under semantic/hybrid (exact COUNT prohibitive on vector-filtered sets). | operator, agent |
| **`system_discover_packages`** | **Intent-based semantic discovery — describe a capability ("reverse proxy", "distributed cache") and get ranked packages.** Pure cosine-distance ranking via pgvector. Inputs: `intent` (required), `repository_ids[]`, `kind`, `architectures[]`, `license`, `top_k` (1-50, default 10). Returns `{results: [{package_id, name, version, architecture, summary, similarity, repository_id, reason}], seed_count, confidence (high/medium/low)}`. Use `system_search_packages` instead when you already know the package name. | operator, agent |
| `system_get_package` | Fetch one Package row with full metadata (depends, recommends, provides, conflicts, license, maintainer) | operator, agent |
| `system_resolve_package_dependencies` | Preview the dependency closure of a package without writes — required + recommends candidates the operator can opt into | operator, agent |
| `system_create_module_from_package` | Materialize a package + transitive deps as NodeModule rows + ModuleDependency edges; dispatches CI build per architecture | operator, agent |
| `system_list_package_module_links` | Auditable provenance — which NodeModules came from which packages, top-level vs auto-generated | operator, agent |
| `system_refresh_package_module` | Re-materialize a NodeModule when upstream drifts (replays persisted `recommends_chosen` for deterministic refreshes) | operator, agent |
| `system_suggest_architectures_for_fleet` | T2.B — fleet-aware architecture suggestion for materialization; intersects repo's archs with NodePlatform coverage | operator, agent |

**Embedding pipeline:** `Package.embedding` (pgvector 1536-dim) is populated by `SystemPackageEmbeddingJob` (worker-side). The job is auto-enqueued after every sync that upserts ≥1 row, and can be manually run via `rake system:packages:backfill_embeddings`. Without embeddings, hybrid mode contributes only the trigram leg — search still works, just without semantic ranking.

**Permission map:**
- `system.package_repositories.{view,create,update,delete,sync,manage_shared}` — repository CRUD + sync
- `system.packages.{view,search}` — catalog read access (search covers both `search` and `discover`)
- `system.package_modules.{view,create,refresh}` — materialization + provenance
- `system.packages.embed` (worker-only) — embedding writeback
- `system.packages.reembed` (operator) — manual re-embed campaigns

#### Architecture catalog

| Action | What it does | Audience |
|---|---|---|
| `system_list_architectures` | List `System::Architecture` rows in the account catalog | operator, agent |
| `system_get_architecture` | Fetch one row with its package list + capability tags | operator, agent |
| `system_create_architecture` | Create a new architecture (named composition of packages + capabilities) — autonomy-gated via `system.architecture.create` policy | operator, agent |
| `system_update_architecture` | Edit packages / capability tags on an existing architecture | operator, agent |
| `system_delete_architecture` | Remove an architecture; refuses if any Node references it | operator, agent |
| `system_propose_architecture` | Operator-facing review surface — propose a new architecture for human approval before catalog insertion | operator, agent |

**Permissions:** `system.architectures.{view,create,update,delete,propose}`

#### GitOps reconciliation

| Action | What it does | Audience |
|---|---|---|
| `system_gitops_register_repository` | Register a Git repository as a fleet-state source (URL + branch + auth ref) | operator, agent |
| `system_gitops_sync_repository` | Trigger a sync (fetch + parse fleet.yaml + compute diff against effective state) | operator, agent |
| `system_gitops_get_sync_run` | Fetch one sync run with the diff payload + proposed change set | operator, agent |
| `system_gitops_get_drift_report` | Per-repository drift summary (rows that diverge from declared state) | operator, agent |
| `system_gitops_apply_proposal` | Apply a proposed change set — gated via `Ai::AgentProposal` approval | operator, agent |

**Permissions:** `system.gitops.{view,sync,apply}`

#### Disk image CI publication management

| Action | What it does | Audience |
|---|---|---|
| `system_list_disk_image_publications` | List publications for a NodePlatform (filterable by status / arch / git_sha) | operator, agent |
| `system_list_disk_image_webhooks` | List webhook rows (per-pipeline; the URL embeds the webhook UUID) | operator, agent |
| `system_set_default_disk_image_publication` | Flip the platform's default-boot publication to a different row | operator, agent |
| `system_set_disk_image_retention` | Set per-NodePlatform `retention_count` (count-based; 7-day grace fixed) | operator, agent |
| `system_list_disk_image_publications` (also exposed inline) | Operator-curated listing for the UI's publications panel | operator |

**Permissions:** `system.disk_image_publications.{view,set_default,retain}`, `system.disk_image_webhooks.view`

See [`DISK_IMAGE_CI.md`](./DISK_IMAGE_CI.md) for the operator-facing workflow that uses these actions in concert with `bootstrap_disk_image_ci` + `provision_disk_image_webhook`.

#### CI worker provisioning

| Action | What it does | Audience |
|---|---|---|
| `system_provision_ci_worker` | Mint a `Worker` row (role `ci_worker`) + a one-time registration token; operator installs the Gitea Actions runner manually against the token | operator |
| `system_terminate_ci_worker` | Tear down a CI worker row (Gitea deregistration is operator-managed) | operator |
| `system_list_ci_workers` | List CI workers + their last seen-online timestamp | operator, agent |
| `provision_ci_worker` (parent platform alias) | Same as `system_provision_ci_worker`; legacy name from the parent platform tool registry | operator |

**Permissions:** `system.ci_workers.{view,provision,terminate}`

#### Storage assignments + volumes

| Action | What it does | Audience |
|---|---|---|
| `system_list_volumes` | List `System::Volume` rows (filterable by storage_class) | operator, agent |
| `system_get_volume` | Fetch one volume row with its assignment + provider state | operator, agent |
| `system_create_volume` | Create a Volume (logical handle; provider materialization is async) | operator, agent |
| `system_update_volume` | Edit metadata (description, tags) | operator, agent |
| `system_delete_volume` | Remove a volume (refuses while assigned) | operator, agent |
| `system_attach_volume` | Attach a Volume to a NodeInstance | operator, agent |
| `system_detach_volume` | Detach without destroying | operator, agent |
| `system_test_nfs_export` | Probe an external NFS export's reachability + auth before creating an assignment | operator, agent |

**Storage migration (zero-downtime data moves between providers):**

| Action | What it does | Audience |
|---|---|---|
| `system_list_storage_migrations` | List in-flight + recent migrations | operator, agent |
| `system_get_storage_migration` | Detail one migration with progress + steps | operator, agent |
| `system_migrate_storage_component` | Initiate a migration (operator-supplied source/destination + cutover plan) | operator |
| `system_approve_storage_migration` | Approve a proposed migration (when the chain composer surfaces one for review) | operator |
| `system_cancel_storage_migration` | Halt an in-flight migration safely | operator |
| `system_report_storage_migration_progress` | Worker-side progress reporting (worker API; not operator-facing) | worker |
| `system_get_storage_recommendations` | Read the architect's storage-class recommendations for a workload type | operator, agent |
| `system_update_storage_recommendations` | Tune the recommendation matrix | operator |

**Permissions:** `system.volumes.{view,create,update,delete,attach,detach}`, `system.storage_migrations.{view,initiate,approve,cancel}`, `system.storage_recommendations.{view,update}`

#### Provider catalog

| Action | What it does | Audience |
|---|---|---|
| `system_list_providers` | List configured providers (AWS, GCP, Azure, LocalQemu, …) | operator, agent |
| `system_get_provider` | Fetch one provider with its region/instance-type catalog | operator, agent |
| `system_update_provider` | Edit provider config (credentials reference, region allowlist) | operator |

**Permissions:** `system.providers.{view,update}`

#### Ingress + public TLS (VIP → port-map → ACME → reverse proxy)

Backed by `Ai::Tools::SystemIngressTool` (wraps the `ExposeServicePublicly` / `AcmeCertificateProvision` / `ReverseProxyCompose` skill executors). See [`INGRESS_TLS_GUIDE.md`](./INGRESS_TLS_GUIDE.md) for the operator-facing workflow.

| Action | What it does | Audience |
|---|---|---|
| `system_expose_service_publicly` | Expose a service end-to-end: create/reuse an SDWAN VIP, port-map it on the hub, provision a TLS cert for the hostname, regenerate the reverse proxy | operator, agent |
| `system_acme_provision_certificate` | Issue an ACME TLS certificate for a hostname (dns-01 / http-01 / tls-alpn-01); stored as a `System::AcmeCertificate` | operator, agent |
| `system_acme_create_dns_credential` | Create + verify a DNS-01 provider credential (cloudflare, route53, gcloud, digitalocean, hetzner, porkbun, ovh) | operator, agent |
| `system_acme_get_certificate` | Fetch a single `System::AcmeCertificate` (status / expiry / SANs) | operator, agent |
| `system_acme_renew_certificate` | Re-run issuance for an existing certificate | operator, agent |
| `system_acme_revoke_certificate` | Revoke a certificate (irreversible; reason e.g. `key_compromise`) | operator, agent |
| `system_reverse_proxy_compose` | Regenerate the Traefik dynamic config so the platform serves an already-valid issued certificate | operator, agent |

**Permissions:** `system.ingress.manage`, `system.acme.manage`

> `system_acme_provision_certificate` does create + issue in one call; the
> finer-grained `get` / `renew` / `revoke` wrappers and
> `create_dns_credential` are backed by `Ai::Tools::SystemAcmeTool`. See
> [`runbooks/acme-issuance.md`](./runbooks/acme-issuance.md) for the full
> lifecycle.

#### Storage ownership (chown lifecycle)

Backed by `Ai::Tools::SystemStorageOwnerTool`. Manages StorageAssignment ownership (service_user / operator / nobody / root) and tracks the on-node chown that applies it.

| Action | What it does | Audience |
|---|---|---|
| `system_assign_storage_owner` | Assign a StorageAssignment's owner (kind + service user); dispatches the on-node chown | operator |
| `system_list_storage_assignments_by_owner` | Audit query — filter assignments by `owner_kind`, `service_user_username`, `chown_state`, or `node_instance_id` (e.g. "which assignments still use owner_kind=root?") | operator, agent |
| `system_storage_chown_status` | Inspect chown state of one assignment — current state, previous_uid/gid, task id, timestamps, recorded error | operator, agent |
| `system_storage_chown_retry` | Re-dispatch a failed / `manual_required` chown (resets `chown_last_error` → `pending`); `force_complete: true` escape hatch for operator-handled external mounts | operator |

**Permissions:** `system.storage_owner.{assign,view}` (chown status/retry covered by the owner-management grant).

#### GPU + inference

Backed by `Ai::Tools::SystemFleetTool`. Locate GPU-bearing capacity and stand up an inference runtime.

| Action | What it does | Audience |
|---|---|---|
| `system_find_node_with_gpu` | Find live NodeInstances exposing a GPU/accelerator; filter by `gpu_type`, `min_gpu_memory_mb`, minimum GPU count | operator, agent |
| `system_list_instance_types_by_gpu` | List provider instance-type SKUs that carry a GPU (filter by `gpu_type` + min count) — pick a SKU before provisioning | operator, agent |
| `system_deploy_inference_server` | Deploy an inference runtime (ollama) onto a GPU node: assigns `gpu-nvidia-runtime` + `inference-ollama` modules and registers an `Ai::Provider` so the endpoint is consumable | operator, agent |

**Permissions:** `system.instances.view` (discovery) + `system.instances.provision` (deploy).

#### Agent-fleet + agent-to-agent (A2A) substrate

Backed by `Ai::Tools::SystemFleetTool`. The L0–L3 substrate for running agents *on* fleet instances: isolation-tier selection (L0), per-instance platform-MCP grants (L2), agent-to-agent capability tokens + grants (L2.5/A2A), and full agent-fleet orchestration missions (L3). All capability surfaces are **default-deny**.

| Action | What it does | Audience |
|---|---|---|
| `system_list_isolation_tiers` | L0 — list isolation tiers an agent deployment can request (`native` / `gvisor` / `kata` / `firecracker` / `vm`) with their Docker runtime + K8s RuntimeClass mapping | operator, agent |
| `system_grant_instance_mcp_tools` | L2 — grant an instance-agent the platform-MCP tool-name glob patterns it may invoke (default-deny until granted) | operator |
| `system_discover_peers` | A2A — list online, operator-enabled agent peers in the account and the skills they offer (capability discovery) | operator, agent |
| `system_grant_instance_peer_skills` | A2A — grant an instance-agent the peer skill-name glob patterns it may invoke on *other* instances (default-deny) | operator |
| `system_mint_peer_capability_token` | A2A — mint an Ed25519-signed capability token proving `caller_instance` may invoke a `skill` on `target_instance`; gated on the A2A policy | operator, agent |
| `system_authorize_peer_call` | A2A — three-gate, default-deny authorization decision for a peer skill invocation (caller granted + target online/enabled + skill offered) | agent |
| `system_launch_agent_fleet` | L3 — launch an agent-fleet orchestration mission: provision a fleet of agent-instances, grant L2 + L2.5 capabilities, delegate work | operator |
| `system_agent_fleet_status` | L3 — inspect an agent-fleet mission: status, current_phase, member/assignment counts, aggregated report, reaped count | operator, agent |

**Permissions:** `system.a2a.{discover,grant,authorize}`, `system.agent_fleet.{launch,view}`, `system.instances.grant_mcp_tools`.

#### SDWAN-adjacent composition (system_*-prefixed)

These two actions are `system_*`-prefixed (not `system_sdwan_*`) but route through `Ai::Tools::SdwanTool` — they compose multiple SDWAN primitives into one operator-facing call.

| Action | What it does | Audience |
|---|---|---|
| `system_multi_tenant_isolation` | Provision a fully-isolated SDWAN network slice for a single tenant — dedicated overlay with its own VRF + isolated iBGP RIB, non-overlapping /64, default-deny nftables baseline | operator |
| `system_service_discovery_compose` | Make a backend service discoverable across the fleet over the overlay — provisions a VIP (auto-advertised via iBGP) + a VIP-backed front end | operator, agent |

**Permissions:** `system.sdwan.networks.manage` (composition wraps the underlying network/VIP grants).

#### Platform deploy + maintenance (Decentralized Federation surface)

| Action | What it does | Audience |
|---|---|---|
| `system_deploy_platform` | Deploy a **standalone** (sovereign) Powernode platform, or return the deployment wizard payload. **Federated spawns are refused on this surface** — see below | operator |
| `system_platform_maintenance` | Concierge-bound skill — surface fleet-wide maintenance posture + scheduled windows | operator, agent |
| `system_platform_resilience` | Concierge-bound skill — fleet-wide resilience posture + incident recovery suggestions | operator, agent |

**Permissions:** `system.platform.deploy` (deploy), `system.platform.read` (maintenance), `system.platform.scale` (resilience) — per `SystemFleetTool::ACTION_PERMISSIONS`. The latter two are bound to System Concierge. (Note: the auto-generated catalog at `docs/reference/auto/mcp-tools.md` prints the tool class's `REQUIRED_PERMISSION` floor, `system.nodes.read`, for every action — the per-action entries above are what actually gates these calls.)

See [`docs/federation/SPAWN_MODES.md`](./federation/SPAWN_MODES.md) for the spawn-mode comparison.

**Federated spawns do not go over MCP.** A federated deploy mints a single-use
acceptance token, and an MCP tool result is forwarded to the model provider and
persisted with the conversation — so `system_deploy_platform` refuses
`mode: "federated"` and names the operator path in the error
(IMP-c0687cfb3a05). Operators deploy federated platforms over REST:

- `POST /api/v1/system/platform/deployments` (permission `system.platform.deploy`)
  — runs the same `System::PlatformDeploymentOrchestrator` and reveals
  `acceptance_token` exactly once in its HTTP response. This is what the
  Deploy Platform wizard submits to.
- `POST /api/v1/system/federation/children/spawn` — the lower-level spawn
  endpoint, likewise unaffected.

`system_deploy_platform` remains the MCP path for standalone deployments and for
fetching the wizard payload.

#### Additional lifecycle actions

| Action | What it does | Audience |
|---|---|---|
| `system_destroy_instance` | Tear down a NodeInstance immediately (skips drain — operator must accept blast radius) | operator |
| `system_drain_instance` | Graceful shutdown — cordon + drain workloads, then stop services | operator |
| `system_get_silent_instances` | Audit query — list NodeInstances whose `last_heartbeat_at` exceeds the silent threshold | operator, agent |
| `system_refresh_instance_modules` | Force the agent to re-reconcile its module set against the platform's view | operator, agent |
| `system_module_mark_canary` | Mark a module as a honeypot canary (any access emits a high-severity FleetEvent) | operator |
| `system_recycle_pool` | Drain + replace all instances in an `InstancePool` (slice 7 — pool refresh) | operator |
| `system_delete_template` | Remove a NodeTemplate (refuses while in use) | operator |
| `system_unassign_module_from_template` | Drop a module → template binding (orphaned NodeModuleAssignments stay; `purge_stale: true` on re-apply removes them) | operator |
| `system_delete_module` | Remove a NodeModule (refuses while assigned) | operator |
| `system_delete_node` | Remove a Node row (refuses if any NodeInstance still exists; cascade delete is `system_terminate_instance` first) | operator |

**Permissions:** the action verb on the matching resource (`system.{node_instances,node_modules,instance_pools,…}.{view,destroy,delete,recycle,refresh,mark_canary,drain}`).

#### CVE management

| Action | What it does | Audience |
|---|---|---|
| `system_get_cve` | Fetch a single CVE row (CVE-id, severity, affected packages, references) | operator, agent |
| `system_create_cve` | Create a CVE row manually (typically driven by the NVD feed worker; operator override path) | operator |
| `system_delete_cve` | Remove a CVE row (audit-cleanup) | operator |
| `system_get_cve_exposure` | Per-NodeInstance exposure detail — which assigned modules ship the affected packages | operator, agent |

**Permissions:** `system.cves.{view,create,delete}`, `system.cve_exposures.view`. CVE remediation runs through the CVE Responder agent's intervention policies (see [`FLEET_SENSORS.md` §"CVE Responder agent (5 policies)"](./FLEET_SENSORS.md#cve-responder-agent-5-policies)) rather than direct MCP actions.

#### Vault credential rotation

| Action | What it does | Audience |
|---|---|---|
| `system_rotate_vault_transit_pepper` | Rotate the Vault transit pepper used for per-account encryption-key wrapping (DR scenario; rare) | operator |

**Permissions:** `system.vault.rotate_transit_pepper`. See [`runbooks/vault-credential-restoration.md`](./runbooks/vault-credential-restoration.md) for the broader rotation workflow.

### `system_sdwan_*` — SDWAN networking + OVN + IPFIX + host bridges + federation accept (73 actions)

Backed by `Ai::Tools::SdwanTool`. Comprehensive network management.

#### Networks

| Action | What it does |
|---|---|
| `system_sdwan_list_networks` | List Networks in account |
| `system_sdwan_get_network` | Fetch a Network + its topology summary |
| `system_sdwan_create_network` | Create a Network with prefix + routing_mode |
| `system_sdwan_update_network` | Edit metadata (description, routing_mode toggle) |
| `system_sdwan_delete_network` | Destroy a Network and all its peers/VIPs/rules |

#### Peers

| Action | What it does |
|---|---|
| `system_sdwan_list_peers` | List Peers on a Network |
| `system_sdwan_get_peer` | Fetch a Peer + its current handshake state |
| `system_sdwan_attach_peer` | Add a NodeInstance as a Peer; allocates `/128` |
| `system_sdwan_detach_peer` | Remove a Peer from a Network |
| `system_sdwan_get_topology` | Network-wide reachability + handshake summary |

#### Firewall rules

| Action | What it does |
|---|---|
| `system_sdwan_list_firewall_rules` | List rules on a Network |
| `system_sdwan_get_firewall_rule` | Fetch a rule by id |
| `system_sdwan_create_firewall_rule` | Create a rule (selector + action + protocol + port_range) |
| `system_sdwan_update_firewall_rule` | Edit a rule |
| `system_sdwan_delete_firewall_rule` | Remove a rule |

#### Access grants + user devices

| Action | What it does |
|---|---|
| `system_sdwan_list_access_grants` | List active access grants |
| `system_sdwan_create_access_grant` | Issue a single-use bootstrap URL for a user device (15-min default expiry) |
| `system_sdwan_revoke_access_grant` | Revoke a grant — cascades to revoke EVERY device on it. Approval-gated (`sdwan.access_grant_revoke`) — returns `pending: true` + a `deferred_operation_id` until approved |
| `system_sdwan_list_user_devices` | List active UserDevices on a Network |
| `system_sdwan_issue_user_device` | Convert an access grant + user-side public key into a UserDevice |
| `system_sdwan_revoke_user_device` | Revoke ONE UserDevice (cuts off that device's VPN access; siblings and the grant are untouched). Approval-gated (`system.sdwan_user_device_revoke`) — returns `pending: true` + a `deferred_operation_id` until approved |

#### Federation peers (slice 11 — live)

| Action | What it does |
|---|---|
| `system_sdwan_list_federation_peers` | List federation peers on a Network |
| `system_sdwan_get_federation_peer` | Fetch a federation peer |
| `system_sdwan_propose_federation_peer` | Account A proposes peering with Account B (out-of-band — does NOT spawn a child platform; use the children-spawn REST endpoint for that) |
| `system_sdwan_accept_federation_peer` | Account B accepts a proposed peering (moves the row to `status: "accepted"`). Approval-gated (`sdwan.federation_peer_accept`) — returns `pending: true` + a `deferred_operation_id` until approved |
| `system_sdwan_update_federation_peer` | Update a federation peer (e.g. its priority-ordered `endpoints` list) |
| `system_sdwan_revoke_federation_peer` | Cancel a federation relationship from either side |
| `system_sdwan_federation_scan` | Scan for proposed-but-not-accepted peers (for operator review) |
| `system_sdwan_federation_compose` | Stand up a federation overlay topology (hub-and-spoke OR full-mesh) across instances — creates one `Sdwan::Network`, enrolls each member as a peer (hubs `publicly_reachable`), and compiles the routing plan |
| `system_sdwan_set_data_residency` | Stamp a peer with a scalar `data_residency` region/tag (P9.4 enforcement). Approval-gated (`sdwan.federation_peer_data_residency`, seeded `require_approval`) and audited on the peer's trail as `federation.peer.data_residency_changed`; the operator twin is `PATCH /sdwan/federation_peers/:id` with `data_residency` |
| `system_sdwan_get_audit_log` | Read a peer's per-peer WORM audit log (P9.3) |

**Permissions:** `system.sdwan.federation_peers.{view,propose,accept,revoke}`

#### Routing + iBGP

| Action | What it does |
|---|---|
| `system_sdwan_update_peer_lan_subnets` | Declare LAN subnets a peer advertises over iBGP |
| `system_sdwan_update_network_routing_mode` | Toggle network between `static` and `ibgp` |
| `system_sdwan_list_subnet_advertisements` | List active subnet advertisements |
| `system_sdwan_get_routing_summary` | Network-wide routing table summary |

#### Virtual IPs (slice 3)

| Action | What it does |
|---|---|
| `system_sdwan_create_virtual_ip` | Allocate a VIP with primary + failover holders |
| `system_sdwan_list_virtual_ips` | List VIPs on a Network |
| `system_sdwan_get_virtual_ip` | Fetch a VIP + its assignments |
| `system_sdwan_update_virtual_ip` | Edit VIP metadata (failover candidates, name) |
| `system_sdwan_delete_virtual_ip` | Free a VIP back to the network |
| `system_sdwan_failover_virtual_ip` | Promote next failover candidate (manual or scripted via skill) |
| `system_sdwan_list_vip_assignments` | List assignment history (audit trail) |

#### BGP

| Action | What it does |
|---|---|
| `system_sdwan_get_account_bgp` | Fetch per-account ASN + BGP global config |
| `system_sdwan_update_account_as_number` | Set the account's ASN (private 64512–65534) |
| `system_sdwan_get_bgp_sessions` | List iBGP sessions on a Network with their states |
| `system_sdwan_get_bgp_config_for_peer` | Fetch FRR config snippet for a peer (debugging) |

#### Route policies (slice 9)

| Action | What it does |
|---|---|
| `system_sdwan_list_route_policies` | List policies on a Network |
| `system_sdwan_get_route_policy` | Fetch a policy by id |
| `system_sdwan_create_route_policy` | Create a JSONB-statement policy |
| `system_sdwan_update_route_policy` | Edit a policy |
| `system_sdwan_delete_route_policy` | Remove a policy |
| `system_sdwan_compile_route_policy` | Render the FRR route-map + aux objects (audit) |

#### Port mappings

| Action | What it does |
|---|---|
| `system_sdwan_list_port_mappings` | List port mappings on a Network |
| `system_sdwan_get_port_mapping` | Fetch a mapping |
| `system_sdwan_create_port_mapping` | Map an external `:port` → internal `[<peer-/128>]:port` |
| `system_sdwan_update_port_mapping` | Edit a mapping |
| `system_sdwan_delete_port_mapping` | Remove a mapping |

#### Host bridges (Phase O1 — slice 9 host topology)

| Action | What it does |
|---|---|
| `system_sdwan_list_host_bridges` | List `Sdwan::HostBridge` rows (per-host bridge allocations) |
| `system_sdwan_create_host_bridge` | Allocate a new host bridge (operator or Topology Designer) |
| `system_sdwan_activate_host_bridge` | Mark a bridge as active so the agent picks it up on next reconcile |
| `system_sdwan_release_host_bridge` | Release a host bridge back to the pool |

**Permissions:** `system.sdwan.host_bridges.{view,allocate,activate,release}`

#### OVN logical-network composition (Phase O3 — slice 9 OVN integration)

| Action | What it does |
|---|---|
| `system_sdwan_create_ovn_deployment` | Create an OVN deployment on a network (manager + controller + switches) |
| `system_sdwan_delete_ovn_deployment` | Tear down the OVN deployment + its switches/ACLs |
| `system_sdwan_create_ovn_logical_switch` | Create a logical switch in the deployment |
| `system_sdwan_delete_ovn_logical_switch` | Remove a logical switch (refuses while ports are attached) |
| `system_sdwan_create_ovn_logical_switch_port` | Attach a port to a logical switch (typed: localnet / VIF / patch) |
| `system_sdwan_create_ovn_acl` | Create an OVN ACL (direction + match + action — fine-grained pod policy) |
| `system_sdwan_delete_ovn_acl` | Remove an ACL |
| `system_sdwan_list_ovn_acls` | List ACLs on a logical switch |
| `system_sdwan_compile_ovn_plan` | Render the full OVN plan (debug + audit before apply) |

**Permissions:** `system.sdwan.ovn.{view,deploy,destroy,configure}` — composed via `Topology Designer` agent's `sdwan_ovn_compose_topology` skill in typical use.

#### IPFIX flow telemetry (Phase O5 — slice 9 observability)

| Action | What it does |
|---|---|
| `system_sdwan_list_ipfix_collectors` | List the account's IPFIX collectors |
| `system_sdwan_get_ipfix_collector` | Fetch one collector, including `is_winning_collector` (only the oldest active row is stamped onto the OVS bridges) |
| `system_sdwan_create_ipfix_collector` | Register a collector endpoint (host + port) for flow export |
| `system_sdwan_update_ipfix_collector` | Enable/disable a collector — **use this, not delete, to stop flow export** |
| `system_sdwan_delete_ipfix_collector` | Remove a collector **and every flow sample recorded against it** (`dependent: :destroy` + cascade FK) |

**Permissions:** `system.sdwan.ipfix.read` (list/get) and `system.sdwan.ipfix.manage` (create/update/delete) — see `Ai::Tools::SdwanTool::ACTION_PERMISSIONS`, which is the authority. (The `system.sdwan.ipfix_collectors.{view,create,delete}` names this table carried previously were never implemented.) Composition typically runs through the `sdwan_ipfix_collector_compose` skill (Topology Designer).

Delete is not a stand-in for disable: it cascades the collector's `flow_samples`, taking with it the correlation history `System::Fleet::Sensors::SdwanServiceHealthSensor` reads. `system_sdwan_update_ipfix_collector` stops the export and keeps both (IMP-6bbe5c673c38).

### `kubernetes_*` — Phase 2 K3s clusters (5 actions)

Backed by `Ai::Tools::KubernetesClusterTool` + `KubernetesProvisioningTool`. Phase 2 ships read + decommission + kubeconfig retrieval; cluster creation is implicit (assigning `k3s-server` module to a NodeInstance creates a cluster).

| Action | What it does |
|---|---|
| `kubernetes_list_clusters` | List clusters in the account |
| `kubernetes_get_cluster` | Fetch cluster details (status, flavor, api_endpoint, node count) |
| `kubernetes_list_nodes` | List KubernetesNodes for a cluster (control-plane + workers) |
| `kubernetes_decommission_cluster` | Cascade-delete cluster + its KubernetesNodes (NodeInstances NOT terminated) |
| `kubernetes_get_kubeconfig` | Retrieve kubeconfig YAML + api_endpoint VIP |

### `docker_*` — Docker daemon management (52 actions)

Backed by 7 tool classes: `DockerContainerTool`, `DockerServiceTool`, `DockerStackTool`, `DockerClusterTool`, `DockerHostTool`, `DockerImageTool`, `DockerNetworkVolumeTool`. Works on **both managed** (Powernode-provisioned) and **external** (operator-registered) hosts. Per memory `powernode.docker_mcp_tools`.

#### Containers

| Action | What it does |
|---|---|
| `docker_list_containers` | List containers on a host |
| `docker_get_container` | Detailed info on one container |
| `docker_create_container` | Create from an image |
| `docker_start_container` / `docker_stop_container` / `docker_restart_container` | Lifecycle |
| `docker_delete_container` | Remove (force flag available) |
| `docker_container_logs` | Retrieve logs (tail + since filters) |
| `docker_container_stats` | Live CPU/mem/network I/O stats |
| `docker_container_exec` | Execute a command in a running container |

#### Services (Swarm)

| Action | What it does |
|---|---|
| `docker_list_services` / `docker_get_service` / `docker_create_service` / `docker_update_service` | Lifecycle |
| `docker_scale_service` | Scale to N replicas |
| `docker_rollback_service` | Rollback to previous version |
| `docker_delete_service` | Remove a service |
| `docker_service_logs` | Aggregated logs across all tasks |
| `docker_service_tasks` | List tasks with status + node placement |

#### Stacks (Swarm)

| Action | What it does |
|---|---|
| `docker_list_stacks` / `docker_get_stack` | Inspection |
| `docker_deploy_stack` | Deploy/redeploy from Compose YAML |
| `docker_delete_stack` | Remove all services in a stack |
| `docker_adopt_stack` | Adopt an externally-deployed stack into Powernode |

#### Cluster (Swarm)

| Action | What it does |
|---|---|
| `docker_list_clusters` / `docker_get_cluster` / `docker_cluster_health` | Inspection |
| `docker_list_nodes` | List nodes with role + availability |
| `docker_node_promote` / `docker_node_demote` | Worker ↔ manager |
| `docker_node_drain` / `docker_node_activate` | Drain/resume scheduling |
| `docker_list_secrets` / `docker_create_secret` / `docker_delete_secret` | Swarm secrets |
| `docker_list_configs` / `docker_create_config` / `docker_delete_config` | Swarm configs |

#### Hosts

| Action | What it does |
|---|---|
| `docker_list_hosts` | List all Docker hosts (managed + external) |
| `docker_get_host` | Detailed host info (OS, resources, Docker version) |
| `docker_sync_host` | Refresh containers/images from daemon |
| `docker_test_host` | Test connection to a host |

#### Images

| Action | What it does |
|---|---|
| `docker_list_images` | List images with tags + size |
| `docker_pull_image` | Pull from registry |
| `docker_delete_image` | Remove (force flag available) |
| `docker_tag_image` | Tag with new repo + tag |

#### Networks + volumes

| Action | What it does |
|---|---|
| `docker_list_networks` / `docker_create_network` / `docker_delete_network` | Network lifecycle |
| `docker_list_volumes` / `docker_create_volume` / `docker_delete_volume` | Volume lifecycle |

## Aspirational backlog

The aspirational backlog is currently **empty** — the three previously-listed wrappers (`system_get_task`, `system_revert_disk_image`, `system_update_module_assignment`) were implemented on 2026-06-04 and are now registered in `platform_api_tool_registry.rb`. If a runbook or tutorial later references an action that isn't yet registered, append a row to [`.verify/ASPIRATIONAL_MCP.md`](./.verify/ASPIRATIONAL_MCP.md) (with a REST workaround at the call site) so the doc-verification harness output stays interpretable; remove the row when the wrapper ships.

Operator runbooks under `docs/runbooks/` should reference current registry actions only; cross-validate against this doc + the aspirational catalog before adding a new runbook step.

## How to add a new action

1. Pick the right tool class in `server/app/services/ai/tools/` (parent) — extend if it fits a domain; create new if introducing a new resource family.
2. Implement the action method on the tool class. Return a `{ success: bool, data: hash, error: string }` shape.
3. Add an entry to `platform_api_tool_registry.rb` — `"my_new_action" => "Ai::Tools::MyTool"`.
4. Add `action_definitions` for the new action describing `description`, `parameters`, `permission`. The MCP server uses these to advertise the tool to clients.
5. Add a permission row in a migration (`db/migrate/<timestamp>_add_<name>_permission.rb`).
6. Run `bundle exec rails mcp:generate_tool_catalog` — regenerates `docs/platform/MCP_TOOL_CATALOG.md` (gitignored).
7. Update this `MCP_API_REFERENCE.md` with the new action — the manually-curated subset for operators.

## Counts

| Prefix | Unique actions | Tool classes |
|---|---|---|
| `system_*` (excl. sdwan) | 128 | `SystemFleetTool` + `SystemArchitectureCatalogTool` + `SystemPackageRepositoryTool` + `DockerProvisioningTool` + `DiskImageOperatorTool` + `SystemIngressTool` + `SystemAcmeTool` + `SystemStorageOwnerTool` + topology / storage tools |
| `system_sdwan_*` | 73 | `SdwanTool` (incl. OVN + IPFIX + host-bridge + federation accept/compose subsections) |
| `kubernetes_*` | 5 | `KubernetesClusterTool` + `KubernetesProvisioningTool` |
| `docker_*` | 52 | 7 tool classes (Container, Service, Stack, Cluster, Host, Image, NetworkVolume) |
| **Total** | code-derived from `platform_api_tool_registry.rb` — regenerate the machine catalog (`rails mcp:generate_tool_catalog`) for the authoritative count; the aspirational backlog ([`.verify/ASPIRATIONAL_MCP.md`](./.verify/ASPIRATIONAL_MCP.md)) is now empty | |

> Counts are code-derived from `platform_api_tool_registry.rb` on 2026-06-03. The parent platform's full machine-generated catalog (with parameter schemas) is the authoritative cross-check — regenerate it with `cd server && bundle exec rails mcp:generate_tool_catalog`.

## Related docs

- [`SKILL_EXECUTORS.md`](./SKILL_EXECUTORS.md) — skill executors (compose multiple MCP actions into orchestrations); [`SKILL_EXECUTOR_CATALOG.md`](./SKILL_EXECUTOR_CATALOG.md) is the auto-generated full list
- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) — fleet sensors (signals → autonomy actions → MCP action invocation)
- [`runbooks/`](./runbooks/) — operator runbooks (use these MCP actions in concrete workflows)
- `server/app/services/ai/tools/platform_api_tool_registry.rb` (parent platform) — source of truth for action-to-tool mapping

_Last verified: 2026-06-03 (rev 2)_
