# Operator Runbooks

> Status: active

Step-by-step procedures for production operations on the System extension.
Each runbook is focused on **one workflow** an operator might run — for
the broader learning sequence, see [`../tutorials/`](../tutorials/).

## Index

| Runbook | Audience | Prerequisites | Runtime |
|---------|----------|----------------|---------|
| [acme-issuance.md](./acme-issuance.md) | SREs, security operators | DNS provider token, Vault transit | ~10–30 min per cert |
| [acme-smoke.md](./acme-smoke.md) | SREs validating ACME, release gate operators | Cloudflare token, test domain, `powernode-hub` ready | ~30 min |
| [cve-response.md](./cve-response.md) | Security operators, on-call SREs | Fleet with SBOM-ingested modules, `system.cve_remediate` approval | ~1–4 hours per CVE |
| [disk-image-ci.md](./disk-image-ci.md) | Platform engineers, CI maintainers | Gitea runner, Vault credentials for OCI registry | ~30 min setup + per-build runtime |
| [expose-service.md](./expose-service.md) | SREs publishing public services, network operators | SDWAN network + publicly-reachable hub peer, free VIP CIDR, Cloudflare ACME DNS credential (https) | ~10–20 min per service |
| [federation-setup.md](./federation-setup.md) | Multi-region / multi-account operators | Two reachable platforms, partner trust agreement | ~30 min per pairing |
| [federation-troubleshooting.md](./federation-troubleshooting.md) | Operators triaging federation failures | Established federation peer in degraded state | ~5–60 min depending on cause |
| [fleet-imaging-claim-by-id.md](./fleet-imaging-claim-by-id.md) | Operators provisioning physical fleets (SD/USB/NVMe) | `system.instances.create`+`read`, published generic image for the arch | ~5 min/device after one image flash |
| [governance-gaps.md](./governance-gaps.md) | Platform operators reviewing the Platform Architect's improvement offers | `ai.agents.manage` (the `Platform Architect Actions` chain), the Autonomy panel | ~5 min per offer |
| [gitops-reconciliation.md](./gitops-reconciliation.md) | SREs adopting GitOps, multi-engineer teams | Git remote (Gitea / GitHub), Vault SSH credential | ~30 min initial setup |
| [instance-pool-tuning.md](./instance-pool-tuning.md) | ML engineers, batch operators, CI platform owners | Provider quota for pool members | ~30 min initial sizing |
| [k3s-smoke-full-lifecycle.md](./k3s-smoke-full-lifecycle.md) | System operators validating the K3s + SDWAN surface before a release / post-incident | Local platform running, `local_qemu` provider, seeded k3s modules | varies by tier (db / single / site / full) |
| [module-authoring.md](./module-authoring.md) | Module authors, platform contributors | Gitea repo + cosign + oras CLIs | ~45 min per new module |
| [multi-cluster-k3s.md](./multi-cluster-k3s.md) | Kubernetes-focused operators | Multiple NodeInstances + SDWAN | ~1 hour per cluster |
| [node-provisioning.md](./node-provisioning.md) | New operators, on-call SREs | Provider connection configured | ~5–15 min per node |
| [publish-service.md](./publish-service.md) | SREs publishing internal services to their own users | An overlay backend (VIP or host) + an account TLS cert; `system.ingress.manage` | ~5 min per service |
| [sdwan-network-setup.md](./sdwan-network-setup.md) | Network engineers, multi-tenant operators | At least one NodeInstance with publicly-reachable address | ~30 min |
| [storage-migration.md](./storage-migration.md) | Storage / SRE operators | Source + target `ProviderVolume`, `system.storage.*` + `system.platform.scale` perms | Varies by data size |
| [template-authoring.md](./template-authoring.md) | Template designers, SREs preparing a node type, agents driving the same flow over MCP | A `NodePlatform` on the account, the `NodeModule` rows to compose, `system.templates.*` | ~20 min per template |
| [traefik-tcp-exposure-vs-dnat.md](./traefik-tcp-exposure-vs-dnat.md) | SREs and network operators deciding how to expose a service | None to read; some paths depend on unbuilt campaign increments (marked planned) | ~5 min decision + per-path setup time |
| [vault-credential-restoration.md](./vault-credential-restoration.md) | Security operators handling Vault DR | Vault snapshot, Shamir unseal keys | ~30 min – 2 hours |
| [vendored-binary-bump.md](./vendored-binary-bump.md) | Platform maintainers updating Traefik / rpi4-firmware / dracut / kernel pins | Clean working tree; for ARM-only items, Pi 4 or QEMU-aarch64 | 15–60 min per bump |

## When to read which

| If you're… | Start with |
|------------|------------|
| New to the extension | [`../tutorials/01-first-boot.md`](../tutorials/01-first-boot.md) → then specific runbooks |
| Provisioning a new node | [node-provisioning.md](./node-provisioning.md) |
| Imaging a fleet of physical devices | [fleet-imaging-claim-by-id.md](./fleet-imaging-claim-by-id.md) |
| Setting up SDWAN | [sdwan-network-setup.md](./sdwan-network-setup.md) |
| Publishing a service publicly with TLS | [expose-service.md](./expose-service.md) (after [sdwan-network-setup.md](./sdwan-network-setup.md)) |
| Publishing a service to your own users at `/svc/<slug>` | [publish-service.md](./publish-service.md) |
| Deciding whether a service belongs on Traefik or nftables DNAT (TCP/TLS/UDP) | [traefik-tcp-exposure-vs-dnat.md](./traefik-tcp-exposure-vs-dnat.md) |
| Migrating a stateful component's data to another volume | [storage-migration.md](./storage-migration.md) |
| Authoring a module | [module-authoring.md](./module-authoring.md) → [disk-image-ci.md](./disk-image-ci.md) (if base image too) |
| Composing modules into a reusable NodeTemplate | [template-authoring.md](./template-authoring.md) (after [module-authoring.md](./module-authoring.md)) |
| Responding to a security CVE | [cve-response.md](./cve-response.md) |
| Building federation | [federation-setup.md](./federation-setup.md) → [federation-troubleshooting.md](./federation-troubleshooting.md) when stuck |
| Adopting GitOps | [gitops-reconciliation.md](./gitops-reconciliation.md) |
| Managing TLS certs | [acme-issuance.md](./acme-issuance.md) for day-2, [acme-smoke.md](./acme-smoke.md) for release gates |
| Validating K3s + SDWAN before a release | [k3s-smoke-full-lifecycle.md](./k3s-smoke-full-lifecycle.md) |
| Recovering Vault | [vault-credential-restoration.md](./vault-credential-restoration.md) |

## Authoring conventions

When writing a new runbook:

1. **Lead with audience + prerequisites** — readers should know in 30
   seconds whether this is for them
2. **Numbered steps** with code blocks; copy-pasteable beats prose
3. **Expected outcome lines** after each side-effecting step
4. **Failure mode section** — list 5–10 common errors with diagnosis +
   remediation
5. **Cross-references** at the end — link to tutorials, design docs, and
   sibling runbooks
6. **Add a row to this index** when shipping

For learning-oriented content (concept refreshers, builds-on chains), use
[`../tutorials/`](../tutorials/) instead. Runbooks are for operators who
already know the concepts and need the procedure.

_Last verified: 2026-06-26_
