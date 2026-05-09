# Powernode System Extension — Architecture

This document is the canonical design reference for the system extension.
It complements [README.md](../README.md) (operator-facing summary) and
[CONTRIBUTING.md](../CONTRIBUTING.md) (development workflow).

---

## Three-tier model

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       OPERATOR + AI SURFACE                             │
│  • UI: Template Composer, Fleet Dashboard, Module Detail (Autonomy tab) │
│  • MCP: ~25 system_* tools                                              │
│  • REST: /api/v1/system/* (operator-facing) + /worker_api (worker token)│
│  • ActionCable: SystemChannel (tasks/nodes) + SystemFleetChannel (events)│
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────────┐
│                       CONTROL PLANE (Rails 8)                           │
│  • System extension models (~50): Node, NodeInstance, NodeTemplate,     │
│    NodeModule + NodeModuleVersion (AASM promotion lifecycle),           │
│    NodeModuleAssignment, ModuleArtifact, BootstrapToken,                │
│    NodeCertificate, FleetEvent, Cve + CveExposure, Slo::Definition      │
│  • Services (~80): ProvisioningService, ModuleBuildDispatchService,     │
│    ModuleOciIngestService, InternalCaService, FleetAutonomyService,     │
│    DecisionEngine, EventBroadcaster, AttributionFeedbackService,        │
│    ConsentBudgetService, NodeEnrollmentService, ModulePromotionService  │
│  • Controllers: 3 surfaces — operator JWT, worker token, node mTLS      │
│  • Worker: SystemFleetReconcileJob (60s), SystemCveFeedJob (1h),        │
│    SystemFleetEventRetentionJob (4:30 AM), SystemTaskReaperJob (1h)     │
└──┬─────────────────────────────────────────────────────────────────────┬┘
   │ webhook + dispatch_to_runner                                        │ mTLS
┌──▼──────────────────────┐                                ┌─────────────▼──┐
│  GITEA + ACTIONS        │  oras pull oci://...           │  NODE INSTANCE │
│  Module CI:             │ ───────────────────────────►   │  ┌──────────┐  │
│   buildah → mkcomposefs │                                │  │powernode-agent │  │
│   → fs-verity → cosign  │                                │  │  (Go)    │  │
│   → push (multi-arch)   │                                │  └─┬────────┘  │
└─────────────────────────┘                                │ /sysroot       │
                                                           │ overlayfs:     │
                                                           │  lower: composefs(modules…)│
                                                           │  upper: tmpfs   │
                                                           │  + bind /var   │
                                                           │     /persist/var│
                                                           └────┬───────────┘
                                                                │ heartbeat + tasks
                                                                │ + events
                                                                ▼
                                                       (back to Control Plane)
```

---

## Subsystems

### 1. Module supply chain

Modules are the unit of deployable composition. A `NodeModule` row in the
control plane has many versions (`NodeModuleVersion`); each version
ultimately resolves to an OCI artifact in the registry, signed by cosign,
with an fs-verity root hash for tamper detection at file open.

**Two-stage CI pipeline** (preserves the legacy rsync-glob composition layer
while modernizing the underlying tools):

```
Stage 1 — Builder
  Inputs: source repo (Containerfile, rootfs/, manifest.yaml) +
          server-computed package_spec
  Steps:  buildah bud --platform linux/amd64,linux/arm64
            FROM ubuntu@sha256:<pinned-digest>
            RUN apt-get install -y $(< package_spec.txt)
            COPY rootfs/ /
  Output: fat builder image with the full filesystem

Stage 2 — Composer
  Inputs: server-computed effective rsync_spec (mask + file_spec +
          effective_mask from priority-aware neighbor analysis)
  Steps:
    rsync -aH --filter="$(cat rsync_spec.filter)" /builder-rootfs/ /module-staging/
    mkcomposefs --digest-store=/cfs-store /module-staging/ /module.cfs
    fsverity enable /module.cfs && fsverity digest /module.cfs > root_hash.txt
    syft /module-staging/ -o cyclonedx-json > sbom.cdx.json
    grype /module-staging/ -o json > vex.json
    cosign sign-blob --bundle module.cosign-bundle /module.cfs
    in-toto-attest --type slsa-provenance-v1 ... > provenance.json
    oras push <registry>/<account>/<module>:<version> [+all attestations]
```

The webhook receiver at `POST /webhooks/gitea/module` ingests the artifact
into a new `NodeModuleVersion` row + `ModuleArtifact` row(s) — one
artifact per architecture.

**Promotion lifecycle** (`NodeModuleVersion#promote_to!`):
`built → staging → blessed → live → retired`, gated by `PromotionCriteria`
(N successful instances run version V for ≥ M minutes).

### 2. On-node runtime (`powernode-agent`)

A single static Go binary (~20 MB) replaces legacy bash. Embedded in the
initramfs, runs as a systemd service after switch_root.

**Identity discovery** is multi-cloud:
- AWS IMDS v2 (`169.254.169.254/latest/user-data`)
- GCP (`Metadata-Flavor: Google`)
- Azure (`Metadata: true`)
- DigitalOcean / Hetzner / KubeVirt / vSphere
- libvirt/QEMU virtio-fw-cfg (`/sys/firmware/qemu_fw_cfg/by_name/`)
- DMI SMBIOS UUID + kernel cmdline fallback

**Enrollment:** bootstrap token → CSR → `/node_api/enroll` → mTLS cert
(stored at `/persist/var/lib/powernode/pki/`, file mode 0600). Subsequent
calls authenticate via mTLS with certificate pinning.

**Module fetch:**
- `oras pull` via `github.com/oras-project/oras-go/v2`
- Cosign verify against per-module trust policy
  (`cosign_identity_regexp` + `cosign_issuer_regexp`)
- SLSA provenance verify
- fs-verity enable + verify root_hash matches `NodeModuleVersion.fsverity_root_hash`

**Mount orchestration:**
- composefs lower stack assembled from priority-ordered modules
- overlayfs (lower=composefs, upper=tmpfs, work=tmpfs)
- `/var` bind from `/persist/var` (LUKS-encrypted; key sealed to TPM
  where present, fallback to Vault-fetched unwrap)

**Long-lived service:**
- 30s heartbeat with `{boot_id, agent_version, module_digests, mount_state, load, mem}`
- Task lease via atomic `FOR UPDATE SKIP LOCKED` on `/node_api/tasks/lease`
- Cert auto-rotate at 75% of lifetime
- Event telemetry to `/node_api/events`
- Module-as-Skill registrar (declared skills register with `Ai::Skill`)

### 3. Multi-arch initramfs builder

Six artifact families per architecture, both amd64 and arm64:

| Artifact | Use case |
|---|---|
| Kernel + initramfs.cpio.zst bundle | PXE/iPXE network boot, libvirt direct kernel boot |
| Raw disk image (`.img`) | USB / SD card / direct dd |
| ISO 9660 image (`.iso`) | DVD/USB, IPMI virtual media |
| iPXE chainload script (`.ipxe.erb`) | Network boot entry; rendered per-instance |
| Cloud `.qcow2` image | libvirt/QEMU pre-baked rootfs |
| OCI image (bootc-compatible) | Container-image-as-OS path |

Built by `extensions/system/initramfs/build.sh --arch {amd64,arm64}`. The
on-disk template `images/ipxe/template.ipxe.erb` is rendered server-side
by `System::NetbootService.render_ipxe_script` with a fresh
`BootstrapToken` per call.

### 4. Fleet autonomy

Six sensors detect operational signals:
- `InstanceStatusSensor` — heartbeat older than 3 × interval → `system.instance_silent`
- `ModuleDriftSensor` — `running_module_digests` ≠ assigned digests → `system.module_drift`
- `CertificateExpirySensor` — cert within advisory/urgent window → `system.cert_expiring`
- `ModulePromotionSensor` — staging version meets PromotionCriteria → `system.module_promotion_ready`
- `ConfigDriftSensor` — assignment changed without dispatched task → `system.config_drift`
- `SloViolationSensor` — Slo::Definition target not met → `system.slo_violation`
- `HoneypotAccessSensor` — canary module accessed → `system.honeypot_access`
- `TradingPressureSensor` — cross-domain consumer of `trading.*` signals

Each signal routes through `DecisionEngine` (binds signal → skill →
action_category) → `FleetAutonomyService.gate_action!` (consults
`Ai::InterventionPolicy` + `ConsentBudgetService` per-module ceiling) →
either auto-execute, notify-and-proceed, open `Ai::ApprovalRequest`, or
defer (for cross-domain pressure). 

Every step persists a `FleetEvent` row + ActionCable broadcast on
`SystemFleetChannel` for live UI consumption.

### 5. Cross-domain stigmergic coordination

Fleet ↔ Trading bidirectional pressure exchange via the platform's existing
`Ai::Coordination::StigmergicSignalService`:

**Fleet emits** (after every reconcile tick):
- `system.capacity_pressure` — instance utilization too low (<50%) or too high (>90%)
- `system.fleet_error_pressure` — recent high/critical FleetEvent ratio
- `system.region_busy:<region_id>` — per-region instance saturation

**Fleet consumes:**
- `trading.high_load`, `trading.market_pressure`, etc. → `TradingPressureSensor` aggregates → `TradingAwareThrottle` defers non-critical fleet actions

**Trading consumes:**
- `system.capacity_pressure` → `Trading::FleetPressurePerceiver` returns
  defer/block recommendation → `OverseerAutonomyService.gate_action!`
  defers `FLEET_DEFERRABLE_ACTIONS` (session creation, scheduling, spawning)

**Trading emits:**
- `trading.venue_busy:<venue_slug>` → consumed by either side via
  `recommend_least_busy_key`

### 6. Observability

`System::FleetEvent` is the durable event log:
- Schema: `kind, severity, payload (jsonb), correlation_id, source, account_id, +optional resource refs`
- GIN index on payload, composite (account_id, emitted_at), correlation_id index
- Retention: 90 days for routine (low/medium severity), 365 days for critical (high/critical) — sweep nightly via `SystemFleetEventRetentionJob`

`SystemFleetChannel` (ActionCable) broadcasts to `system_fleet:<account_id>`
for live UI updates. Frontend's `FleetDashboardPage` subscribes + renders
correlation chains.

`AttributeFailureExecutor` walks recent FleetEvents + assignment changes +
promotions to rank likely causes of an instance failure. Operator
confirms/rejects via `AttributionFeedbackService` → `Ai::CompoundLearning`
→ next executor invocation boosts (1.5x) confirmed pairs, downweights
(0.7x) rejected.

### 7. Honeypot canaries

`System::Honeypot::CanaryModuleService.mark!` flips a config flag on a
NodeModule. Any subsequent access via `observe_access!` emits a
high-severity FleetEvent. `HoneypotAccessSensor` reads recent events,
emits `system.honeypot_access` (always `:critical`), DecisionEngine routes
to `system.instance_terminate` (`require_approval`).

Operator dashboard: `HoneypotCanaryTile` shows 24h + 7d access counts
with alert badge when 24h > 0.

### 8. Container runtimes (Phase 1 Docker, Phase 2 K3s, Phase 3 kubeadm)

Operator-managed container workloads on NodeInstances. Three runtime
modules in the catalog: `docker-engine`, `k3s-server`, `k3s-agent`.

- **Auto-registration**: assigning a runtime module to a Node triggers
  the agent to install the daemon, generate cert material (Docker) or
  capture k3s-generated state, and POST `runtime/handshake`. Platform
  creates the corresponding `Devops::DockerHost` (1:1 with NodeInstance)
  or `Devops::KubernetesCluster` (1:N — multiple NodeInstances per
  cluster via `Devops::KubernetesNode`).

- **Network binding**: all daemon API traffic flows over the SDWAN
  overlay `/128`. No public daemon sockets — encrypted by default.
  Docker binds `tcp://[<sdwan-/128>]:2376`; K3s binds
  `https://[<sdwan-/128>]:6443`.

- **Trust model**:
  - Docker — platform issues mTLS material via
    `System::InternalCaService` (90-day cert TTL); `Devops::DockerHost
    .encrypted_tls_credentials` stores client cert+key.
  - K3s — k3s ships its own CA + signs its own certs; platform
    captures the kubeconfig + tokens via the agent's `bootstrap`
    handshake phase. Operators download kubeconfig from the platform
    UI for kubectl access.

- **Dedicated agent**: `Runtime Manager` (monitor-type AI agent) owns
  container runtime autonomy with 8 intervention policies — separate
  trust score + approval queue from Fleet Autonomy. Allows
  per-domain policy tuning (e.g. auto-rotate `docker_daemon_tls`
  certs while keeping `kubernetes_cluster_decommission` gated).

- **Phase 3 kubeadm** uses the same shape — extends `RUNTIME_MODULES`
  in the runtime/handshake controller, adds parallel kubeadm
  provisioner service. Both flavors share the
  `Devops::KubernetesCluster` model with a `flavor` enum.

See `CONTAINER_RUNTIMES.md` for the operator workflow.

---

## API surfaces

### 1. Operator-facing JWT (`/api/v1/system/*`)

Standard Rails routes for CRUD on every System resource. Permission-gated
via `current_user.has_permission?('system.<resource>.<action>')`.

Notable non-CRUD endpoints:
- `POST /node_templates/compose_preview` — Visual Composer's live preview
- `GET /netboot/:instance_id/script.ipxe` — operator generates iPXE chainload
- `POST /fleet/signals` — recent FleetEvent log
- `POST /fleet/attribute_failure` — AttributeFailureExecutor wrapper
- `POST /fleet/attribution_feedback` — confirm/reject attribution
- `POST /node_modules/:id/mark_canary` + `unmark_canary` — honeypot toggle

### 2. Worker token (`/api/v1/system/worker_api/*`)

Authenticated via `X-Worker-Token` (SHA-256 digest comparison).

- `POST /worker_api/fleet/reconcile` — invoked by SystemFleetReconcileJob
- `POST /worker_api/cve/ingest` — invoked by SystemCveFeedJob
- `POST /worker_api/fleet/events` — agent-side telemetry batches
- `POST /worker_api/fleet/retention_sweep` — nightly retention sweep

### 3. Node mTLS (`/api/v1/system/node_api/*`)

Authenticated via mTLS subject CN matching the NodeInstance.id, with
fallback to instance JWT during transition.

- `POST /node_api/enroll` — bootstrap token → cert exchange (the only
  bootstrap-token-authenticated endpoint; everything else is mTLS)
- `POST /node_api/certificates/{rotate,revoke}`
- `GET  /node_api/{config,modules,status,ssh_keys,mount_points,puppet/resources,files/scripts/:id,files/modules/:id/:filename}`
- `POST /node_api/status/heartbeat`
- `GET  /node_api/tasks/lease?max=N`
- `POST /node_api/tasks/:id/{progress,complete,fail}`
- `POST /node_api/events`

### 4. MCP (`mcp__powernode__platform_system_*`)

25+ tool actions exposed via the platform's MCP server, callable from
any AI agent or Claude Code MCP client. See [MCP_TOOL_CATALOG.md](../../../docs/platform/MCP_TOOL_CATALOG.md)
in the parent platform.

---

## Security architecture

### Trust boundaries

1. **OCI registry digest** — module identity is `oci_digest + cosign signature`
2. **Internal CA** — root signs node certs; ideally HSM-sealed via Vault PKI
3. **Control plane** — JWT for operators (with MFA on sensitive actions),
   InterventionPolicy gating for AI agents
4. **Zero implicit trust on network location** — mTLS for `/node_api/*`,
   WireGuard mesh for east-west, default-deny egress at node level

### Key custody

- **Internal CA root** in HashiCorp Vault PKI engine
- **Node certificates** issued by `pki_int`, 90-day TTL, auto-rotated
  at 75% lifetime by powernode-agent
- **Cosign signing identity** uses Sigstore Fulcio with ephemeral
  OIDC-bound certs (no long-lived signing keys)
- **Bootstrap tokens** SHA-256 hashed in DB, single-use, 1-hour TTL,
  bound to `intended_subject`

### Supply chain

- **SLSA Build Level 3+** for module CI (ephemeral runners, isolated
  build environment, signed in-toto provenance attestations)
- **Reproducible builds** as a CI gate (pinned base image digest, pinned
  Debian snapshot URLs, pinned package versions)
- **SBOM (CycloneDX) + VEX (grype)** attached to every artifact as OCI
  referrers
- **Per-module trust policy** pinning each module to its expected
  cosign identity + OIDC issuer

### On-node runtime

- **fs-verity** mandatory at file open on every composefs lower
- **Lockdown mode** (`lockdown=integrity`) on kernel cmdline by default
- **IMA/EVM** for additional file integrity (defense-in-depth)
- **Per-module SELinux/AppArmor profiles** loaded by powernode-agent on attach
- **Capability dropping** by default — modules declare required caps in
  manifest.yaml; everything else dropped
- **seccomp filter** on powernode-agent itself (highest-privilege process)
- **Egress filtering** at node level — default-deny outbound except
  platform endpoints + manifest.yaml allowlist

---

## Where to read more

- [README.md](../README.md) — user-facing summary
- [CONTRIBUTING.md](../CONTRIBUTING.md) — development workflow
- [docs/TASKS.md](./TASKS.md) — active milestone tracker
- [Parent platform's CLAUDE.md](https://github.com/nodealchemy/powernode-platform/blob/master/CLAUDE.md) — full platform context
- [agent/README.md](../agent/README.md) — Go agent details
- [initramfs/README.md](../initramfs/README.md) — boot artifact builder details

---

*Last updated 2026-05-02 during the system extension extraction.*
