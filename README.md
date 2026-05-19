# Powernode System Extension

A self-contained extension for the [Powernode platform][platform] that provides
node lifecycle management, declarative module composition, on-node
runtime, and a self-improving fleet autonomy layer.

This repository is mounted into the Powernode platform as a submodule at
`extensions/system/`. It can be operated independently — the platform consumes
it via the standard extension contract.

[platform]: https://github.com/nodealchemy/powernode-platform

---

## What this extension provides

### Operator surface

- **Node + instance lifecycle** with a polymorphic Task model + AASM state
  machines covering `pending → provisioning → running → stopped → terminated`
- **Declarative templates** composed from versioned NodeModules with
  rsync-glob filter rules (`mask`, `file_spec`, `package_spec`, `dependency_spec`)
- **Cloud provider abstractions** (AWS, GCP, Azure, OpenStack, local QEMU) with
  per-region/zone catalogs
- **Visual Template Composer** in the React UI — drag modules onto a canvas,
  preview conflicts + footprint live, save with one click
- **Fleet Dashboard** — live event feed, correlation chains, drift queue,
  honeypot canary alerts, attribution feedback for failure analysis

### On-node runtime

- **Go agent (`powernode-agent`)** — single static binary, ~20MB, replaces legacy
  bash scripts. Multi-cloud identity discovery (AWS/GCP/Azure/DigitalOcean/
  libvirt fw-cfg), mTLS enrollment, OCI module pull, fs-verity verification,
  composefs+overlayfs union mount, heartbeat, task lease, cert rotation
- **Multi-arch initramfs builder** — produces six artifact families per arch
  (kernel+initramfs bundle, raw disk image, ISO, iPXE chainload, qcow2,
  bootc-compatible OCI) for both amd64 and arm64 in one CI run

### Module supply chain

- **Two-stage CI pipeline** (Containerfile builder + composefs composer) that
  preserves the legacy rsync-glob composition layer while modernizing
  multistrap → mmdebstrap and mksquashfs → mkcomposefs
- **Cosign-signed OCI artifacts** with Sigstore Fulcio (no long-lived signing
  keys; ephemeral OIDC-bound certs)
- **Per-module trust policy** (`cosign_identity_regexp` + `cosign_issuer_regexp`)
  pinning each module to its expected publisher

### AI-driven autonomy

- **12 fleet sensors** detecting silent instances, module drift, cert expiry,
  promotion readiness, config drift, SLO violations, honeypot canary access,
  trading pressure (cross-extension stigmergic coordination), and SDWAN
  health (peer reachability, BGP session, VIP reachability, drift)
- **40 AI Skill executors** spanning read-shape (concierge chat), fleet autonomy
  (drift remediation, CVE response, module composition, rolling upgrades),
  SDWAN topology composition + remediation, container runtime provisioning,
  package + module authoring, architecture catalog, federation, and platform
  deployment. See [`docs/SKILL_EXECUTORS.md`](./docs/SKILL_EXECUTORS.md) for
  the catalog with descriptors and example I/O.
- **FleetAutonomyService** — gates every autonomous action through
  intervention policy + approval chain (auto_approve / notify_and_proceed /
  require_approval / blocked); same UI as trading-overseer's approval queue
- **Learning loop** — every confirmed/rejected operator decision feeds back
  into compound learnings that boost or downweight similar candidates next time
- **Cross-domain stigmergic coordination** — bidirectional pressure exchange
  with trading and other extensions via the platform's signal bus
- **Per-module consent budget** — operators set a daily ceiling on autonomous
  decisions per module; exhausted budget forces require_approval regardless
  of policy

### Observability

- **System::FleetEvent** persistent log (90-day routine retention,
  365-day critical retention) with per-tick correlation IDs
- **SystemFleetChannel** ActionCable broadcast for live UI updates
- **Compliance snapshot** — audit-grade JSON document of every node, instance,
  module digest, certificate, CVE exposure, drift state, and autonomy decision

---

## Requirements

To operate this extension you need a running Powernode platform installation.
See [the parent platform repo][platform] for installation instructions.

This extension contributes:
- Rails models, services, controllers (98 models across `system::*` + `sdwan::*`,
  ~285 service classes incl. 40 skill executors across 11 subdomains, ~138
  controllers across operator API + on-node API + worker API)
- React/TypeScript frontend (~250 TS/TSX files including 11 page components +
  ~156 reusable components + custom hooks + API client services)
- Worker jobs (12): `system_task_reaper`, `system_fleet_reconcile`,
  `system_cve_feed`, `system_cve_responder_reconcile`,
  `system_fleet_event_retention`, `system_cloud_sync`, `system_execute_task`,
  `system_gitops_sync`, `system_package_embedding`,
  `system_package_module_materialize`, `system_package_module_refresh`,
  `system_package_repository_sync`
- Database migrations (131)
- Sidekiq cron schedule entries

---

## Layout

```
extensions/system/
├── server/                 # Rails models, services, controllers, specs
├── frontend/               # React TypeScript surface
├── worker/                 # Sidekiq job classes
├── agent/                  # Go on-node agent (powernode-agent)
├── initramfs/              # Multi-arch boot artifact builder
├── templates/
│   └── module-repo/        # Canonical module-source layout
└── docs/
    ├── ARCHITECTURE.md     # Subsystem reference
    ├── tutorials/          # Numbered learning sequence (01-first-boot → 12-disk-image-ci)
    ├── runbooks/           # Step-by-step operator guides
    ├── history/            # Archived phase plans + acceptance reports
    └── …                   # Domain-specific reference (see Documentation)
```

---

## Documentation

### Reference

| Doc | What it covers |
|---|---|
| [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) | 8 subsystems, threat model, state machines, API surfaces |
| [`docs/USE_CASE_MATRIX.md`](./docs/USE_CASE_MATRIX.md) | What works / doesn't / what to expect for 10 NodeInstance container scenarios — **READ FIRST when designing a deployment** |
| [`docs/CONTAINER_RUNTIMES.md`](./docs/CONTAINER_RUNTIMES.md) | Phase 1 Docker + Phase 2 K3s lifecycle + operator troubleshooting |
| [`docs/SKILL_EXECUTORS.md`](./docs/SKILL_EXECUTORS.md) | Skill executor catalog (40 executors with descriptors and example I/O) |
| [`docs/FLEET_SENSORS.md`](./docs/FLEET_SENSORS.md) | All 12 fleet sensors + intervention policy reference table |
| [`docs/DISK_IMAGE_CI.md`](./docs/DISK_IMAGE_CI.md) | Webhook + CI worker + OCI artifact pipeline |
| [`docs/MCP_API_REFERENCE.md`](./docs/MCP_API_REFERENCE.md) | All `system_*` / `system_sdwan_*` / `kubernetes_*` / `docker_*` MCP tool actions |

### Operator runbooks

See [`docs/runbooks/README.md`](./docs/runbooks/README.md) for the full index with audience + prerequisites + runtime per runbook. Highlights:

| Runbook | Goal |
|---|---|
| [`docs/runbooks/node-provisioning.md`](./docs/runbooks/node-provisioning.md) | Full Node + NodeInstance lifecycle (create → enroll → drain → decommission) with per-AASM-state error recovery |
| [`docs/runbooks/sdwan-network-setup.md`](./docs/runbooks/sdwan-network-setup.md) | SDWAN end-to-end: networks, peers, VIPs, firewall, route policies, BGP, federation |
| [`docs/runbooks/module-authoring.md`](./docs/runbooks/module-authoring.md) | Author + register + sign + publish a new NodeModule |
| [`docs/runbooks/cve-response.md`](./docs/runbooks/cve-response.md) | Full CVE response workflow with SBOM-aware matching |
| [`docs/runbooks/gitops-reconciliation.md`](./docs/runbooks/gitops-reconciliation.md) | Operator workflow for GitOps reconciler: fleet.yaml, sync, proposal review, apply |
| [`docs/runbooks/acme-issuance.md`](./docs/runbooks/acme-issuance.md) | ACME DNS-01 cert lifecycle: provider setup, issue, renew, revoke, endpoint failover |
| [`docs/runbooks/acme-smoke.md`](./docs/runbooks/acme-smoke.md) | P2.5.7 acceptance smoke test (6 scenarios) |
| [`docs/runbooks/instance-pool-tuning.md`](./docs/runbooks/instance-pool-tuning.md) | Pool sizing, reaping, draining, troubleshooting |
| [`docs/runbooks/multi-cluster-k3s.md`](./docs/runbooks/multi-cluster-k3s.md) | Multi-cluster K3s with `target_cluster_id` + HA control plane |
| [`docs/runbooks/disk-image-ci.md`](./docs/runbooks/disk-image-ci.md) | Disk image build + signing + publication operator workflow |
| [`docs/runbooks/federation-setup.md`](./docs/runbooks/federation-setup.md) | Multi-region / multi-account federation peering |
| [`docs/runbooks/federation-troubleshooting.md`](./docs/runbooks/federation-troubleshooting.md) | Diagnosing federation peering failures |
| [`docs/runbooks/docker-compose-cutover.md`](./docs/runbooks/docker-compose-cutover.md) | Migrating legacy compose deployments to Powernode |
| [`docs/runbooks/vault-credential-restoration.md`](./docs/runbooks/vault-credential-restoration.md) | DR runbook for credential restoration |

### Tutorials

[`docs/tutorials/`](./docs/tutorials/) — numbered, dependency-aware learning sequence (beginner → advanced):

| # | Tutorial | What it teaches |
|---|----------|-----------------|
| 01 | [First boot (single-node QEMU)](./docs/tutorials/01-first-boot.md) | Catalog seed, kernel + initrd, local QEMU, agent enrollment |
| 02 | [Your first custom module](./docs/tutorials/02-first-module.md) | manifest.yaml, rsync globs, Containerfile, cosign-keyless |
| 03 | [Container runtime — Docker](./docs/tutorials/03-docker-runtime.md) | docker-engine module, mTLS handshake, SDWAN binding |
| 04 | [Container runtime — K3s cluster](./docs/tutorials/04-k3s-cluster.md) | k3s-server/agent, VIP-backed api_endpoint, multi-node join |
| 05 | [Multi-cluster K3s + SDWAN isolation](./docs/tutorials/05-multi-cluster-k3s.md) | target_cluster_id, per-tenant SDWAN, trust boundary |
| 06 | [Rolling module upgrade with canary](./docs/tutorials/06-rolling-upgrade.md) | rolling_module_upgrade, circuit breaker, attribution feedback |
| 07 | [CVE response end-to-end](./docs/tutorials/07-cve-response.md) | ExposureCalculator, CveResponseExecutor, orchestrated rebuild |
| 08 | [Instance pools for bursty batch](./docs/tutorials/08-instance-pool.md) | InstancePool, atomic acquire, reaper auto-replenishment |
| 09 | [Honeypot canaries](./docs/tutorials/09-honeypot-canary.md) | mark_canary, HoneypotAccessSensor, intervention policy |
| 10 | [GitOps-managed fleet](./docs/tutorials/10-gitops-fleet.md) | fleet.yaml, sync cycle, proposal review |
| 11 | [Multi-region federation](./docs/tutorials/11-federation.md) | Spawn modes, P9.x data residency + WORM audit + schema negotiation |
| 12 | [Disk image CI publication](./docs/tutorials/12-disk-image-ci.md) | DiskImageWebhook, CI worker, signed OCI artifact, retention |

Start with [`docs/tutorials/INDEX.md`](./docs/tutorials/INDEX.md) for a Mermaid decision tree mapping your goal to a starting tutorial.

### Subsystem-specific

- [`docs/SMOKE_TEST.md`](./docs/SMOKE_TEST.md) — platform-level smoke catalog (16 seeded scripts across 7 passes; covers boot, container runtimes, SDWAN, federation, ACME, storage, credentials)
- [`docs/credential-restoration.md`](./docs/credential-restoration.md) — Vault transit credential design
- [`docs/agent-peering.md`](./docs/agent-peering.md) — NodeInstance-as-Agent design
- [`docs/agent-internals.md`](./docs/agent-internals.md) — Go agent package-by-package reference (23 internal packages)
- [`docs/gitops.md`](./docs/gitops.md) — GitOps reconciler design
- [`docs/history/`](./docs/history/) — archived phase plans + acceptance reports
- [`initramfs/README.md`](./initramfs/README.md) — multi-arch boot artifact builder
- [`agent/README.md`](./agent/README.md) — Go agent build + 16 subcommands (architecture in `docs/agent-internals.md`)
- [`templates/module-repo/README.md`](./templates/module-repo/README.md) — canonical module-source layout

---

## Development

```bash
# Inside the Powernode platform working tree, where this extension is mounted
# as a submodule at extensions/system/

cd extensions/system

# Backend specs
cd server && bundle exec rspec

# Frontend type-check
cd ../frontend && npx tsc --noEmit

# Go agent tests
cd ../agent && go test ./...
```

When working on this extension, always commit inside `extensions/system/`
first, then update the submodule pointer in the parent platform repo. See
[CONTRIBUTING.md](./CONTRIBUTING.md) for the full submodule workflow.

---

## License

MIT — see [LICENSE](./LICENSE). Code of Conduct: see [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).

---

## Community

**Text channels**

- **GitHub issues** — [nodealchemy/powernode-system/issues](https://github.com/nodealchemy/powernode-system/issues) for bugs + feature requests
- **X / Twitter** — [@nodealchemy](https://x.com/nodealchemy) for general updates and informal questions

**Email**

- [contact@nodealchemy.com](mailto:contact@nodealchemy.com) — general inquiries
- [support@nodealchemy.com](mailto:support@nodealchemy.com) — technical support
- [sales@nodealchemy.com](mailto:sales@nodealchemy.com) — commercial + enterprise-tier inquiries
- [security@nodealchemy.com](mailto:security@nodealchemy.com) — security vulnerabilities; see [SECURITY.md](./SECURITY.md)
- [conduct@nodealchemy.com](mailto:conduct@nodealchemy.com) — Code of Conduct reports; see [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)

---

## Status

Active development. Spec coverage: **1,430 examples / 0 failures** (as of
2026-05-04). The Golden Eclipse roadmap (Track A through Track F) is
substantially complete on backend + autonomy axes; frontend operator surface
covers M-FE-1 (Visual Composer) and M-FE-3 (Fleet Dashboard, with Boot Replay
viewer in active sweep).

### Recent shipments (May 2026)

- **Slice 3** — first-class `Sdwan::VirtualIp` with cluster `api_endpoint`
  VIP failover (bootstrap-node loss → automatic VIP failover to next
  `k3s-server` holder; kubectl + worker `K3S_URL` survive the transition)
- **Slice 7** — pre-warmed `System::InstancePool` with atomic acquisition
  + reaper auto-replenishment; cuts ephemeral provisioning latency from
  5–10 min cold-boot to <30 s claim
- **Slice 9 (a–f)** — static subnet routing, first-class VIPs, iBGP/FRR,
  comprehensive frontend, observability/autonomy, route policies (JSONB
  statements compiled to FRR route-map + prefix-list/as-path-list)
- **Slice 10** — config-variety dockerd `daemon.json` overrides via
  dependant module hierarchy (per-node + per-instance customization
  without rebuilding the base module)
- **Phase 2 K3s** — full container runtime stack: cluster provisioner,
  agent reconciler state machine, module catalog seed, multi-cluster
  `metadata.target_cluster_id` join validation
- **Phase 1 Docker** — managed `Devops::DockerHost` with InternalCaService
  TLS provisioning + cascade-FK decommission

### Milestones complete

- **M0** — Foundation contracts + legacy spec porting (BootstrapToken,
  NodeCertificate, ModuleArtifact, mTLS, AASM)
- **M2** — Go agent v0 (~4,400 LOC across 9 packages including security)
- **M3** — Multi-arch image builder (six artifact families × amd64/arm64)
- **M4** — QEMU thin slice (LocalQemuProvider with Libvirt/Recorder/Disabled
  runner triplet, virtio-fw-cfg seed, 15-spec integration coverage)
- **M5** — MCP CRUD surface (SystemFleetTool, ~25 actions, per-action
  permission gates)
- **M6** — AI Skills catalog (8 executors)
- **M7** — FleetAutonomyService (gate_action!, 8 sensors, DecisionEngine,
  approval chains)
- **M8** — Compound learning extraction (LearningExtractor wired into tick
  loop, auto-evolve trigger after 3 matching learnings)

### Active sweep (May 2026)

Per-account encryption key restoration via Vault transit, SBOM-aware CVE
matching (M-D2-2), GitOps reconciliation (M-D2-3), NodeInstance-as-Agent
peer registration (F-3), Boot Replay viewer (M-FE-3 completion), Module
Marketplace skeleton (M-FE-2), AI Concierge chat (M-FE-4). For historical
phase tracking see [`docs/history/TASKS.md`](./docs/history/TASKS.md).

---

## Related

- [Powernode platform][platform] — the parent platform that mounts this extension
- [Cosign](https://github.com/sigstore/cosign) — module signing
- [composefs](https://github.com/containers/composefs) — verified-mount lower layer
- [oras](https://github.com/oras-project/oras) — OCI artifact tooling
