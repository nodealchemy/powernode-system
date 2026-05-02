# Powernode System Extension

A self-contained extension for the [Powernode platform][platform] that provides
node lifecycle management, declarative module composition, on-node
runtime, and a self-improving fleet autonomy layer.

This repository is mounted into the Powernode platform as a submodule at
`extensions/system/`. It can be operated independently — the platform consumes
it via the standard extension contract.

[platform]: https://github.com/rett/powernode-platform

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

- **Go agent (`ipn-agent`)** — single static binary, ~20MB, replaces legacy
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

- **6 fleet sensors** detecting silent instances, module drift, cert expiry,
  promotion readiness, config drift, and SLO violations
- **9 AI Skill executors** (drift_remediate, provision_cluster,
  rolling_module_upgrade, cve_response, capacity_recommend, module_compose,
  runbook_generate, attribute_failure)
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
- Rails models, services, controllers (~50 models, ~80 services, ~30 controllers)
- React/TypeScript frontend components (~50 components)
- Worker jobs (system_task_reaper, system_fleet_reconcile, system_cve_feed,
  system_fleet_event_retention)
- Database migrations (~30)
- Sidekiq cron schedule entries

---

## Layout

```
extensions/system/
├── server/                 # Rails models, services, controllers, specs
├── frontend/               # React TypeScript surface
├── worker/                 # Sidekiq job classes
├── agent/                  # Go on-node agent (ipn-agent)
├── initramfs/              # Multi-arch boot artifact builder
├── templates/
│   └── module-repo/        # Canonical module-source layout
└── docs/                   # Architecture + operational guides
```

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

MIT — see [LICENSE](./LICENSE).

---

## Status

Active development. Spec coverage: 1262 examples / 0 failures (as of
2026-05-02). The Golden Eclipse roadmap (Track A through Track F) is
substantially complete on backend + autonomy axes; frontend operator surface
covers M-FE-1 (Visual Composer) and M-FE-3 (Fleet Dashboard).

---

## Related

- [Powernode platform][platform] — the parent platform that mounts this extension
- [Cosign](https://github.com/sigstore/cosign) — module signing
- [composefs](https://github.com/containers/composefs) — verified-mount lower layer
- [oras](https://github.com/oras-project/oras) — OCI artifact tooling
