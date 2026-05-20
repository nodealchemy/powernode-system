# K3s full-lifecycle smoke runbook

End-to-end operator workflow for the Pass 9 K3s lifecycle smoke. Covers
all 8 phases across 4 tiers (db / single / site / full). Use this when
you need to verify the K3s + SDWAN capability surface end-to-end after
upgrades, new feature work, or before a release cut.

> Counterpart: [SMOKE_TEST.md §Pass 9](../SMOKE_TEST.md#pass-9--k3s-full-lifecycle-smoke).
> Related: [multi-cluster-k3s.md](multi-cluster-k3s.md), [sdwan-network-setup.md](sdwan-network-setup.md), [federation-setup.md](federation-setup.md), [cve-response.md](cve-response.md).

## Audience

System operators verifying the platform's K3s + SDWAN capability surface
after platform changes, before a release, or as part of post-incident
validation. **Not for end-user-facing fleet deploys** — those use the
production CLI flow documented in [`tutorials/04-k3s-cluster.md`](../tutorials/04-k3s-cluster.md).

## Prerequisites

### Always required

- Powernode platform running locally (`server/`, `worker/`, `frontend/`
  via systemd or `scripts/dev/start.sh`)
- Postgres reachable (`development` database seeded)
- At least one `Account`, one admin `User`, one `local_qemu` `Provider`,
  and the `base` `NodeTemplate` + `k3s-server`/`k3s-agent` modules
  (`bundle exec rails db:seed` covers all of these via the standard
  catalog seeds)

### Required at `single` tier and above

| Requirement | How to install |
|---|---|
| KVM (`/dev/kvm` readable) | `sudo apt install qemu-kvm` + add user to `kvm` group |
| libvirt + virsh | `sudo apt install libvirt-daemon-system libvirt-clients virtinst` |
| Initramfs build artifacts | `cd extensions/system/initramfs && ./build.sh` |
| Writable fw-cfg dir | `mkdir -p /tmp/powernode-fwcfg` |
| ≥4 GB RAM headroom per VM | 16 GB host minimum at single tier; 32 GB at site tier; 64 GB at full tier |

If `/dev/kvm` is unavailable, set `SMOKE_K3S_KVM_AVAILABLE=0` to allow
TCG fallback (~6× slower). The preflight respects this and multiplies
all `wait_until` timeouts accordingly.

### Required at `site` tier and above

- `kubectl` binary in PATH (or override via `SMOKE_K3S_KUBECTL=/path/to/kubectl`)
- `tcpdump` with sudo (for pod-plane verification on `wg-sdwan-*`)
- Cross-network routing configured on the host (the WG SDWAN tunnel comes
  up automatically from agent enrollment)

### Required at `full` tier only

- Both Site A and Site B clusters running (phases 1-4 completed for each
  site via `SMOKE_K3S_SITE=a` then `SMOKE_K3S_SITE=b`)
- Federation propose/accept executors registered (default install)

## Tier matrix

| Tier | Runtime | Peak RAM | Validates |
|---|---|---|---|
| `db` (default) | ~5 min | ~0 GB VM RAM | Operator-driven flow: state machines, executors, plan generation, instrumentation |
| `single` | ~15 min | ~4 GB | + Real LocalQemu boot + agent enrollment + on-VM k3s install |
| `site` | ~45 min | ~12 GB | + HA control plane + 2 agents + kubectl + tcpdump on wg-sdwan-* |
| `full` | ~90 min | ~24 GB | + Site B mirror + cross-site federation |

Each tier is a superset of the prior. Set `SMOKE_K3S_LEVEL=<tier>`; lower
tiers run their checks, higher-tier-only phases (4 site+, 5 full, 9 site+)
print `⊘ skipped (tier=...)`.

## Environment template

```bash
# ── Always required ──────────────────────────────────────────────────
export SMOKE_K3S_LEVEL=db          # db | single | site | full
export SMOKE_K3S_AUTO_CLEAN=1       # auto-destroy stale Devops::KubernetesCluster
                                    # rows. Omit on shared environments.

# ── Optional ─────────────────────────────────────────────────────────
export SMOKE_K3S_SITE=a             # a | b — controls phase 1 site selection
                                    # (default: a). Re-run with =b for Site B.
export SMOKE_K3S_POD_PREFIX_A=172.30.0.0/16  # override Site A pod CIDR
export SMOKE_K3S_POD_PREFIX_B=172.31.0.0/16  # override Site B pod CIDR
export SMOKE_K3S_PAUSE=1            # add interactive checkpoints between phases
export SMOKE_K3S_VIP_REAL_FAILOVER=1  # phase 2: real failover via instance terminate
export SMOKE_K3S_FEDERATION_REVOKE=1  # phase 5: also exercise revoke at end
export SMOKE_K3S_KUBECTL=/usr/local/bin/kubectl  # override kubectl path
export SMOKE_K3S_KVM_AVAILABLE=0    # accept TCG fallback (×6 timeouts)

# ── single+ tier (real VM boot via LocalQemuProvider) ───────────────
export POWERNODE_LIBVIRT_MODE=real
export POWERNODE_LIBVIRT_URI=qemu:///session
export POWERNODE_PLATFORM_URL=http://localhost:3000
export POWERNODE_AGENT_URL=http://localhost:3000
export POWERNODE_CA_PEM=/etc/powernode/ca.pem
export POWERNODE_IMAGE_BASE=$(realpath extensions/system/initramfs/build)
export POWERNODE_FWCFG_DIR=/tmp/powernode-fwcfg
export POWERNODE_SERIAL_LOG_DIR=/tmp/smoke-serial
```

## Phase invocation

Each phase is `bundle exec rails runner "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_<phase>.rb')"`.
The phases must run in order — each reads the prior phase's state from
`/tmp/smoke-k3s-state.json`.

### Full db-tier sweep (~5 min)

```bash
cd server
export SMOKE_K3S_LEVEL=db SMOKE_K3S_AUTO_CLEAN=1

for phase in site_bootstrap ha_control_plane agent_join pod_plane \
             federation rolling_upgrade cve_drill drain_reprovision; do
  echo "→ Phase: ${phase}"
  bundle exec rails runner \
    "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_${phase}.rb')" \
    || { echo "Phase ${phase} FAILED"; break; }
done
```

Expected: 7 ✅ + 1 ⊘ (federation; needs full tier).

### Phase-by-phase

#### Phase 1 — Site bootstrap

```bash
SMOKE_K3S_LEVEL=db SMOKE_K3S_SITE=a bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_site_bootstrap.rb')"
```

**What it does:** creates an SDWAN network with `pod_subnet_prefix` (default
`172.30.0.0/16` for Site A, `172.31.0.0/16` for Site B), creates a Node +
NodeInstance + SDWAN peer, assigns the `k3s-server` module, then either
bootstraps the cluster directly (db tier) or boots a VM and waits for the
agent-driven bootstrap (single+ tier). Stamps `cluster.metadata["pod_cidr"]`,
allocates a single-holder VIP for `api_endpoint`, creates a SubnetAdvertisement
sourced from `pod_subnet`.

**Validates:** flannel-over-SDWAN feature wiring + slice 3 VIP allocation +
pod_subnet_prefix → SubnetAdvertisement chain.

#### Phase 2 — HA control plane

```bash
SMOKE_K3S_LEVEL=db SMOKE_K3S_SITE=a bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_ha_control_plane.rb')"
```

Adds 2 more k3s-server NodeInstances, registers them via
`register_node_join!(role: "server")`, and verifies the VIP's
`failover_holder_peer_ids` list grows to 2. Triggers a synthetic VIP
failover via `Sdwan::VirtualIp#failover!(reason: "manual_failover")` and
asserts the primary holder changes to one of the HA peers, with the old
primary moving to the failover list.

#### Phase 3 — Agent join

```bash
SMOKE_K3S_LEVEL=db SMOKE_K3S_SITE=a bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_agent_join.rb')"
```

Adds 2 k3s-agent NodeInstances, verifies `cluster.node_count` reaches 5
(3 servers + 2 agents). Negative test: builds a stub
`Devops::KubernetesCluster(cni_plugin: "ovn_kubernetes")`, snaps an agent's
`network_profile` to `lightweight`, and asserts
`KubernetesClusterProvisionerService::CniProfileMismatchError` is raised.

#### Phase 4 — Pod plane

```bash
SMOKE_K3S_LEVEL=db SMOKE_K3S_SITE=a bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_pod_plane.rb')"
```

**db tier:** validates the `runtime_controller#k3s_server_bootstrap_config`
payload (the agent's contract for installing k3s with the right flannel
flags). Asserts `flannel_iface = wg-sdwan-<network_handle>`,
`flannel_backend = host-gw`, `cluster_cidr = <pod_subnet_prefix>`.

**site+ tier:** also deploys a 2-replica nginx Deployment with
podAntiAffinity (so the replicas land on different nodes), waits for both
replicas Ready, and (manually, per runbook) verifies pod-to-pod traffic
across nodes flows through `wg-sdwan-<handle>`. See the **Live pod-plane
verification** section below.

#### Phase 5 — Federation

```bash
SMOKE_K3S_LEVEL=full bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_federation.rb')"
```

Requires Site A + Site B clusters in state (run phases 1-4 with
`SMOKE_K3S_SITE=a` then `SMOKE_K3S_SITE=b` before this phase). Proposes a
`System::FederationPeer` from Site A → Site B (autonomous_peer mode), accepts
on Site B's behalf, asserts the peer status transitions to `accepted` or
`active`. Optional revoke pass via `SMOKE_K3S_FEDERATION_REVOKE=1`.

> Cross-site **pod plane** is explicitly out of scope. Federation extends
> control plane only. Multi-cluster pod-to-pod across federation is
> Submariner / MCS territory (future work).

#### Phase 6 — Rolling upgrade

```bash
SMOKE_K3S_LEVEL=db bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_rolling_upgrade.rb')"
```

Synthesizes a newer `System::NodeModuleVersion` for `k3s-server`, invokes
`System::Ai::Skills::RollingModuleUpgradeExecutor` with valid inputs, and
asserts the executor produces a plan with `batches: [...]` where the first
batch is canary-sized (smallest among all batches). Does not actually
execute the upgrade — Fleet Autonomy's reconciler tick does that in prod.

#### Phase 7 — CVE drill

```bash
SMOKE_K3S_LEVEL=db bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_cve_drill.rb')"
```

Inserts a synthetic `CVE-2026-99099` (drill metadata), invokes
`CveResponseExecutor` to triage + score, then
`CveRunbookGenerateExecutor` to produce a markdown remediation runbook.
Cleans up the drill CVE at end.

#### Phase 8 — Drain + reprovision

```bash
SMOKE_K3S_LEVEL=db bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_drain_reprovision.rb')"
```

Picks one k3s-agent NodeInstance, marks it stopped (db-tier equivalent
of `system_drain_instance`), destroys the KubernetesNode + NodeInstance,
then reprovisions a replacement agent and re-joins it. Asserts
`cluster.node_count` decrements then restores.

## Live pod-plane verification (phase 4, site+ tier)

The headline operator claim is "pod traffic flows over the encrypted
SDWAN overlay." At site+ tier phase 4 deploys the nginx test workload;
verifying actual traffic on `wg-sdwan-<handle>` is a manual sudo step.

```bash
# 1. Get pod IPs after phase 4 completes the nginx deploy
kubectl --kubeconfig=/tmp/k3s-smoke-kubeconfig-a get pods -o wide

# 2. Get the network handle for site A's SDWAN network
NET_HANDLE=$(bundle exec rails runner "puts Sdwan::Network.find_by(name: 'k3s-site-a').network_handle")
IFACE="wg-sdwan-${NET_HANDLE}"

# 3. On any SDWAN-attached host, capture pod-to-pod traffic
sudo tcpdump -i $IFACE -n -c 20 host <pod-a-ip> and host <pod-b-ip>

# 4. From inside pod A, hit pod B
kubectl --kubeconfig=/tmp/k3s-smoke-kubeconfig-a exec pod-a -- wget -qO- http://<pod-b-ip>

# Expected: tcpdump captures 20 packets between the pods on $IFACE
# (proves flannel host-gw is routing pod traffic over the WireGuard tunnel)
```

## Troubleshooting matrix

| Symptom | Cause | Fix |
|---|---|---|
| `PreflightFailed: stale Devops::KubernetesCluster rows present` | Prior smoke run left clusters behind | `SMOKE_K3S_AUTO_CLEAN=1` env, OR `Devops::KubernetesCluster.destroy_all` in console |
| `PreflightFailed: /dev/kvm not readable` | Single+ tier needs KVM | `sudo usermod -aG kvm $USER` + log out / back in; OR `SMOKE_K3S_KVM_AVAILABLE=0` for TCG fallback |
| `PreflightFailed: virsh uri failed` | libvirtd not running | `sudo systemctl start libvirtd` |
| `PreflightFailed: initramfs kernel missing` | Initramfs not built | `cd extensions/system/initramfs && ./build.sh` |
| `PreflightFailed: POWERNODE_FWCFG_DIR not writable` | Default `/var/run/powernode-fwcfg` is root-only | `export POWERNODE_FWCFG_DIR=/tmp/powernode-fwcfg` |
| `PreflightFailed: POWERNODE_LIBVIRT_MODE=real required` | single+ tier set but libvirt env vars not exported | Export the full single+ env template above |
| `Pod subnet prefix must not overlap network 'X' pod_subnet_prefix Y` | Existing dev DB network conflicts with smoke default | Override via `SMOKE_K3S_POD_PREFIX_A=10.250.0.0/16` (or any non-conflicting /16) |
| Phase 5 prints `skipped (federation requires both Site A and Site B)` | Site B never bootstrapped | Re-run phases 1-4 with `SMOKE_K3S_SITE=b` before phase 5 |
| `Tier::Insufficient` from a phase that should run | Misread tier matrix | Check the table above; raise `SMOKE_K3S_LEVEL` |
| `wait_until cluster active timed out` | Real VM boot failed or agent never POST'd bootstrap | Check `cluster.metadata["bootstrap_events"]` (last 50 entries with phase/status); check `/tmp/smoke-serial/*` for kernel log; check `journalctl -u powernode-backend@default` for runtime_controller errors |
| `Validation failed: Reason is not included in the list` (VIP failover) | Wrong `reason` argument | Must be one of `initial`, `manual_failover`, `sensor_failover`, `holder_changed`, `revoked` |

## Teardown

Smoke seeds are idempotent and re-runnable. Full reset:

```bash
# 1. Remove state sidecar
rm -f /tmp/smoke-k3s-state.json

# 2. Destroy all smoke clusters + cascades
SMOKE_K3S_AUTO_CLEAN=1 bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_site_bootstrap.rb')"
# (preflight will auto-clean; then ctrl-C; OR run the full sweep again)

# 3. (Optional) destroy smoke SDWAN networks
bundle exec rails runner '
  Sdwan::Network.where("name LIKE ?", "k3s-site-%").destroy_all
'

# 4. (Optional) destroy smoke Nodes
bundle exec rails runner '
  System::Node.where("name LIKE ?", "k3s-%").destroy_all
'
```

State sidecar is **never** auto-wiped by the smoke; it's the operator's
single point of control for resuming vs. starting over.

## Cross-references

- [`SMOKE_TEST.md`](../SMOKE_TEST.md) — catalog of all 28 smoke seeds
- [`multi-cluster-k3s.md`](multi-cluster-k3s.md) — operator-facing multi-cluster K3s workflow
- [`sdwan-network-setup.md`](sdwan-network-setup.md) — SDWAN end-to-end (networks, peers, VIPs, federation)
- [`federation-setup.md`](federation-setup.md) — multi-region/multi-account federation peering
- [`federation-troubleshooting.md`](federation-troubleshooting.md) — federation diagnostic procedures
- [`cve-response.md`](cve-response.md) — CVE response operator workflow
- [`../tutorials/04-k3s-cluster.md`](../tutorials/04-k3s-cluster.md) — beginner K3s tutorial
- [`../tutorials/05-multi-cluster-k3s.md`](../tutorials/05-multi-cluster-k3s.md) — multi-cluster tutorial
- [`../tutorials/11-federation.md`](../tutorials/11-federation.md) — federation tutorial
- [`../CONTAINER_RUNTIMES.md`](../CONTAINER_RUNTIMES.md) §"Routing pod traffic over SDWAN"
