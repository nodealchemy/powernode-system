# AI/MCP Workload Substrate — Design & Roadmap

Status: **design / in progress** · Owner: platform · Created 2026-06-02

## North-star

Powernode as the substrate on which AI agents build and run distributed AI/MCP
workloads *with ease*. Concretely, the platform must be able to:

1. Provision a **GPU-capable physical server as a managed instance** and serve
   inference (ollama / similar) to other node instances over the overlay.
2. Run **dynamically-provisioned, isolated AI/MCP agent instances** — densely
   (many per server), powernode-agent-managed, memory-efficient.
3. Let those agents **communicate agent-to-agent (A2A) over MCP**, authenticated
   with **mTLS**, discovering each other's capabilities.
4. Drive all of the above as **orchestrated missions** (provision a fleet of
   agents, delegate subtasks, coordinate, aggregate, reap).

**Constraints (hard):** supported paths only — **no `vgpu_unlock`** or other
unsupported GPU hacks; **do not change DNA's PCI/passthrough config**; smoke-test
inference against the **existing ollama `Ai::Provider`** (DNA's running ollama)
or simulate. This design maps 1:1 onto the audit's "AI/MCP workload substrate"
recommendations (`docs/history/operational-completeness-audit-2026-06.md` §AI/MCP).

---

## Architecture — a layered substrate

```
L3  MISSIONS / ORCHESTRATION   provision N hybrid agent instances for a mission,
                               delegate subtasks, coordinate, aggregate, reap
L2½ A2A MESH                   instance↔instance MCP calls, mTLS-authed over SDWAN,
                               capability discovery via agent-peering + grants
L2  AGENT / MCP RUNTIME        instance runs an MCP server (tools) and/or agent
                               worker (hybrid), peers in, consumes L1 inference
L1  SHARED GPU INFERENCE       ollama/similar on a GPU node, published as a service
                               ◀── first implementation slice
L0  ISOLATION (seam now)       isolation tier as a first-class deployment dimension;
                               runtimes implemented incrementally (native → gVisor → microVM)
```

Each layer delivers standalone value and is designed so the layers above slot in
without rework.

---

## Layers in detail (reuse vs. new)

### L0 — Isolation tier (the seam now, runtimes later)

- **Decision:** isolation is split into two separable costs — the **abstraction**
  (cheap, painful to retrofit) and the **runtimes** (heavy, per-host infra). Build
  the abstraction now; implement runtimes incrementally.
- **New (now):** an `isolation_tier` field on the agent-deployment
  (`native | gvisor | kata | firecracker | vm`, default `native`), threaded
  through the docker/k3s deploy path → maps to Docker `--runtime` / K8s
  `RuntimeClass`. Always declared, even when `native`.
- **New (incremental):** `gvisor` (runsc + containerd shim) as the first real tier
  when untrusted agents arrive; `kata`/`firecracker` microVMs later for stronger
  boundaries.
- **Reuse:** `NodeInstance.config` profile pattern; Docker/K3s provisioning.

### L1 — Shared GPU inference *(first slice)*

- **Reuse:** GPU capability on instances (`gpu_count/gpu_type/gpu_memory_mb`,
  `system_find_node_with_gpu` — shipped P6, `provider_instance_type.rb` /
  `node_instance.rb`); `NodeModule` + `ModuleService` (exposed_ports + health);
  `ServiceDiscoveryComposer` (SDWAN VIP + `ServiceOffering` + subscriber Traefik
  routes); ollama `Ai::Provider` + `Ai::ProviderClientService` (full chat/stream
  client, `OLLAMA_API_ENDPOINT`).
- **New:**
  - `gpu-nvidia-runtime` module (nvidia driver + container toolkit) — subscription seed.
  - `inference-ollama` module (ollama binary + `ModuleService` exposing :11434,
    health-checked; `config`: runtime/model/vram_required; depends-on GPU module) — seed.
  - `system_deploy_inference_server` skill/MCP action: pick a GPU node
    (`system_find_node_with_gpu`) → assign both modules → `service_discovery_compose`
    (VIP + offering) → register/point an ollama `Ai::Provider` at the VIP endpoint.

### L2 — Agent / MCP runtime (hybrid)

- **Reuse:** `agent-peering` (`System::NodeInstancePeer.announce!` —
  declared_skills + capabilities + handle + trust_score); `ModuleSkillRegistrar`
  (manifest `skills` → `Ai::Skill`); the platform MCP server
  (`Api::V1::Mcp::StreamableHttpController`).
- **New:**
  - `mcp-server` / `agent` module (or subscription module + manifest skills): the
    instance runs an MCP server and/or an agent worker; **hybrid** — uniform peers
    with declared capabilities.
  - **Instance MCP auth:** add an **mTLS arm** to the MCP endpoint — instance
    presents its node cert (Traefik-forwarded) → resolve `NodeInstance` via
    `Security::MtlsTrust`/`MtlsClientVerifier` → bind a scoped `McpSession`.
    (Alternative: scoped Doorkeeper token issued at provisioning. mTLS preferred —
    reuses identity, no token distribution.)
  - **Scoped catalog:** `tools/list` filtered per agent (the existing
    `concierge_tool_filter` pattern). Verify: instance calls `tools/list` over its
    mTLS session → receives its allowed subset.

### L2½ — A2A mesh (instance↔instance MCP over mTLS)

- **The key reuse:** this is the **federation mTLS pattern applied intra-account,
  instance-to-instance** — but simpler: one **shared account CA** (not two), so
  it's the `MtlsClientVerifier` "verify against our CA + map CN → instance + check
  grant" path I hardened this session.
- **Three gates** (same model as federation, "trust ≠ authorization"):
  1. **Handshake** — mTLS over the SDWAN overlay (WireGuard /128).
  2. **Identity** — peer cert (CN = `NodeInstance.id`) verified against the account
     internal CA; maps to the calling instance.
  3. **Grant** — a per-peer capability ACL decides whether A may invoke B's tool
     (intra-account analog of `FederationGrant`).
- **Discovery:** `NodeInstancePeer.declared_skills` + capabilities; each instance's
  MCP endpoint address is part of its announce.
- **New:** the on-node MCP server endpoint; an A2A grant/ACL model; capability
  discovery surface; mTLS verify reusing core `MtlsClientVerifier`.

### L3 — Missions / orchestration

- **Reuse:** `Ai::Mission` (multi-phase, approval-gated), `Ai::GoalPlan`,
  `SkillCompositionRunner` (per-step execution + output passing), `InstancePool`
  (pre-warmed ephemeral instances + reaper), agent-peering task delegation.
- **New:** a mission pattern that **dynamically provisions a fleet** of isolated
  hybrid agent instances, delegates subtasks (central OR peer-to-peer via A2A),
  coordinates, aggregates, and **reaps** (ephemeral lifecycle via pools).

---

## Key design decisions (firm)

| # | Decision |
|---|----------|
| D1 | **GPU capability** is first-class on instances/SKUs — done (P6). |
| D2 | **Inference** ships as a `NodeModule` + `ModuleService`, published via `ServiceDiscoveryComposer`, consumed via an ollama `Ai::Provider` pointed at the VIP. No new `inference_server` variety yet (subscription module + config is sufficient and needs zero agent changes). |
| D3 | **Instance MCP access** uses the *same* platform MCP endpoint, authenticated by the instance's **mTLS identity** (scoped `McpSession`), serving a **scoped catalog**. |
| D4 | **Agent taxonomy:** `Ai::Agent` = platform-runtime (in-process, inference via `Ai::Provider`); `System::NodeInstancePeer` = instance-based (runs in the fleet, A2A-reachable, tools-as-skills). Unified at the orchestration layer by capability. |
| D5 | **Deployment density:** thin **containers** (Docker / K3s pods) on powernode-agent-managed hosts — **never VM-per-agent**. Inference is **offloaded to the shared GPU node**, so agent containers carry no model/GPU (tens of MB each). VMs only when an isolation tier later demands it. |
| D6 | **Isolation:** build the **seam now** (`isolation_tier`, default `native`); implement **runtimes incrementally** (gVisor first). |
| D7 | **A2A** = three-gate (handshake → identity → grant), shared-account-CA mTLS via `MtlsClientVerifier`, MCP as payload, riding SDWAN. |
| D8 | **Hybrid agents** — instances are uniform peers; a given instance can be a tool-server or an agent-worker per mission step. |

---

## Data-model deltas (incremental, by phase)

- **L1:** `NodeModule` seeds (`gpu-nvidia-runtime`, `inference-ollama`) + a
  `ModuleService`; ollama `Ai::Provider` record pointed at the discovered VIP; a
  `system_deploy_inference_server` action (registry-routed).
- **L2:** instance MCP auth path (mTLS arm) + scoped catalog filter; `mcp-server` /
  `agent` module; `NodeInstancePeer` carries its MCP endpoint address.
- **L0 seam:** `isolation_tier` on the agent-deployment + runtime-class mapping.
- **A2A:** per-peer grant/ACL (intra-account `FederationGrant` analog).
- **L3:** mission template + runner steps for fleet provision/delegate/reap.

---

## Phased roadmap

| Phase | Layer | Deliverable | Verify |
|-------|-------|-------------|--------|
| **1** | L1 | GPU + ollama modules; `system_deploy_inference_server`; ollama `Ai::Provider` wired to the VIP | specs; `db:seed`; **smoke against DNA's real ollama** via the existing provider (no DNA changes); simulated GPU node for the deploy/expose path |
| **2** | L0-seam + L2 | `isolation_tier` dimension; `mcp-server`/`agent` module; instance MCP mTLS auth + scoped catalog | specs; instance `tools/list` over mTLS returns scoped catalog |
| **3** | L2½ | A2A: instance↔instance MCP over mTLS; grant/ACL; capability discovery | specs; two-instance A2A call (simulated) authenticated + grant-gated |
| **4** | L3 | mission-driven dynamic agent fleet (provision → delegate → coordinate → reap) | specs; simulated mission spins up N agents, delegates, reaps |
| later | — | gVisor/microVM runtimes; model-artifact registry; skill A/B + self-improvement; confidential compute (SEV/TDX) | per-slice |

---

## Smoke / test strategy

- **No changes to DNA's PCI/driver config.** Inference smoke uses the **existing
  ollama `Ai::Provider`** pointed at DNA's running ollama (`OLLAMA_API_ENDPOINT`) —
  a real chat round-trip proves the inference path.
- The **deploy / assign / expose / A2A** logic is exercised with **simulated**
  (factory) GPU nodes + instances; the on-node module install is the agent's job,
  tested separately.
- Each phase is test-first; RSpec under the extension; `mcp:generate_tool_catalog`
  after new actions.

---

## Reference: DNA (real GPU node)

`dna.ipnode.net` (10.125.0.10) — Dell host, swarm node, **NVIDIA Quadro RTX 4000,
8 GB**, driver 590.48.01, **host-driver-bound + container-shared** (ollama / emby /
open-webui), clean IOMMU group 2 (passthrough-capable but *not* configured for it).
Single 8 GB card → effectively one inference backend; **shared via the host driver
to containers** is the supported multi-consumer model (which is exactly what L1
serves over the overlay). See memory `powernode.dna_gpu_node`.

---

## Open decisions (track here)

- Primary container runtime for agent density: **Docker** (single-host) vs **K3s**
  (cluster-wide scheduling). Likely both; K3s when fleets span hosts.
- Instance MCP auth: mTLS arm (preferred) vs scoped Doorkeeper tokens — confirm at L2.
- A2A grant granularity: per-tool vs per-capability-set; default-deny.
- Ephemeral vs persistent agents: pools for dynamic/mission agents; persistent for
  long-lived tool-servers.
- Whether to add a `runtime` discriminator/bridge on `Ai::Agent` for a single
  unified agent list (sugar; not required — taxonomy is already structural).
