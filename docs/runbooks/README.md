# Operator Runbooks

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
| [docker-compose-cutover.md](./docker-compose-cutover.md) | Platform operators migrating from legacy compose stacks | Existing compose deployment, SDWAN network defined | ~1–3 days (planned downtime) |
| [federation-setup.md](./federation-setup.md) | Multi-region / multi-account operators | Two reachable platforms, partner trust agreement | ~30 min per pairing |
| [federation-troubleshooting.md](./federation-troubleshooting.md) | Operators triaging federation failures | Established federation peer in degraded state | ~5–60 min depending on cause |
| [gitops-reconciliation.md](./gitops-reconciliation.md) | SREs adopting GitOps, multi-engineer teams | Git remote (Gitea / GitHub), Vault SSH credential | ~30 min initial setup |
| [instance-pool-tuning.md](./instance-pool-tuning.md) | ML engineers, batch operators, CI platform owners | Provider quota for pool members | ~30 min initial sizing |
| [module-authoring.md](./module-authoring.md) | Module authors, platform contributors | Gitea repo + cosign + oras CLIs | ~45 min per new module |
| [multi-cluster-k3s.md](./multi-cluster-k3s.md) | Kubernetes-focused operators | Multiple NodeInstances + SDWAN | ~1 hour per cluster |
| [node-provisioning.md](./node-provisioning.md) | New operators, on-call SREs | Provider connection configured | ~5–15 min per node |
| [sdwan-network-setup.md](./sdwan-network-setup.md) | Network engineers, multi-tenant operators | At least one NodeInstance with publicly-reachable address | ~30 min |
| [vault-credential-restoration.md](./vault-credential-restoration.md) | Security operators handling Vault DR | Vault snapshot, Shamir unseal keys | ~30 min – 2 hours |

## When to read which

| If you're… | Start with |
|------------|------------|
| New to the extension | [`../tutorials/01-first-boot.md`](../tutorials/01-first-boot.md) → then specific runbooks |
| Provisioning a new node | [node-provisioning.md](./node-provisioning.md) |
| Setting up SDWAN | [sdwan-network-setup.md](./sdwan-network-setup.md) |
| Authoring a module | [module-authoring.md](./module-authoring.md) → [disk-image-ci.md](./disk-image-ci.md) (if base image too) |
| Responding to a security CVE | [cve-response.md](./cve-response.md) |
| Building federation | [federation-setup.md](./federation-setup.md) → [federation-troubleshooting.md](./federation-troubleshooting.md) when stuck |
| Adopting GitOps | [gitops-reconciliation.md](./gitops-reconciliation.md) |
| Managing TLS certs | [acme-issuance.md](./acme-issuance.md) for day-2, [acme-smoke.md](./acme-smoke.md) for release gates |
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
