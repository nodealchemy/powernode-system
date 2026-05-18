# Tutorials

A numbered, dependency-aware sequence for learning the Powernode System
extension from first boot to multi-region federation. Each tutorial
declares what the previous one set up and what the next one will extend,
so you can resume mid-sequence without re-reading prior context.

If you're not sure where to start, see [`INDEX.md`](./INDEX.md) — it has a
decision tree that maps your goal to a starting tutorial.

## Sequence

| # | Tutorial | Builds on | Teaches |
|---|----------|-----------|---------|
| [01](./01-first-boot.md) | First boot (single-node QEMU) | — | Catalog seed, kernel + initrd build, local QEMU provisioning, agent enrollment, kernel cmdline tour |
| [02](./02-first-module.md) | Your first custom module | 01 | `manifest.yaml`, rsync globs, Containerfile, Gitea Actions, cosign-keyless, assign via Template |
| [03](./03-docker-runtime.md) | Container runtime — Docker | 01 + 02 | Assigning `docker-engine`, runtime handshake, mTLS provisioning, SDWAN binding |
| [04](./04-k3s-cluster.md) | Container runtime — K3s cluster | 03 | `k3s-server` + `k3s-agent`, VIP-backed `api_endpoint`, multi-node join, kubeconfig |
| [05](./05-multi-cluster-k3s.md) | Multi-cluster K3s with SDWAN isolation | 04 | `target_cluster_id`, per-tenant SDWAN network, cross-tenant trust boundary |
| [06](./06-rolling-upgrade.md) | Rolling module upgrade with canary | 02 + 03 | `rolling_module_upgrade` skill, circuit breaker, attribution feedback |
| [07](./07-cve-response.md) | CVE response end-to-end | 06 | Synthetic CVE → ExposureCalculator → CveResponseExecutor → orchestrated rebuild |
| [08](./08-instance-pool.md) | Instance pools for bursty batch | 03 | `System::InstancePool`, atomic acquire, reaper auto-replenishment |
| [09](./09-honeypot-canary.md) | Honeypot canaries | 01 | `mark_canary`, HoneypotAccessSensor, dashboard tile, intervention policy |
| [10](./10-gitops-fleet.md) | GitOps-managed fleet | 02 + 06 | `fleet.yaml`, repo register, sync cycle, proposal review, auto-apply trade-off |
| [11](./11-federation.md) | Multi-region federation | 04 + 10 | Propose → accept → activate, sovereign auth, P9.x data residency + WORM audit + schema negotiation |
| [12](./12-disk-image-ci.md) | Disk image CI publication | 01 + 02 | DiskImageWebhook, CI worker dispatch, signed OCI artifact, retention |

## Template

Every tutorial follows the same structure so you can scan it without
re-learning the layout:

1. **What you'll learn** — 1–2 sentences naming the capability + outcome
2. **Time** — rough wall-clock estimate
3. **Builds on / Sets you up for** — explicit dependency declaration
4. **Prerequisites** — packages, env vars, prior platform state
5. **Concept refresher** — the model / abstraction this tutorial assumes
6. **Step-by-step** — each step states action + expected outcome
7. **Verification** — exact commands that confirm success
8. **Cleanup** — leaves the system in a known state for the next tutorial
9. **Troubleshooting** — 3–5 common failure modes + remediation
10. **What's next** — pointer to the natural follow-on

## Companion surfaces

- [`../SMOKE_TEST.md`](../SMOKE_TEST.md) — platform-level smoke catalog
  (16 seeded scripts); every tutorial cross-references the smoke that
  validates the same capability at the platform layer.
- [`../runbooks/`](../runbooks/) — operator workflows for specific
  scenarios (CVE response, vault credential rotation, federation
  troubleshooting). Tutorials introduce concepts; runbooks reference them
  for production scenarios.
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — subsystem reference. When
  a tutorial says "this happens via the FleetAutonomyService," the
  architecture doc is where you learn what that service is.
