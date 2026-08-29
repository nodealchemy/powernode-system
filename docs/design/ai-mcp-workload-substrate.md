# AI/MCP Workload Substrate — Design & Roadmap

> Status: active

Owner: platform · Created 2026-06-02

**Shipped status (2026-06-03):** L1–L3 and the A2A mesh (policy + on-node MCP
transport) are **built, tested, and live-smoke-passed**. Only the L0 **isolation
runtimes** (gVisor/Kata/Firecracker) remain deferred — the L0 *seam*
(`isolation_tier`, `system_list_isolation_tiers`) shipped. Per-layer status is
called out inline below and in the phased roadmap. See memory
`powernode.ai_mcp_workload_substrate` for the build/commit trail.

This design maps onto the 2026-06 audit's "AI/MCP workload substrate" North Star
and its ai-substrate gaps; entry points
[`../ARCHITECTURE.md`](../ARCHITECTURE.md) and
[`../../README.md`](../../README.md) link here.

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
L0  ISOLATION (seam shipped)   isolation tier as a first-class deployment dimension;
                               runtimes deferred (native now → gVisor → microVM later)
```

Each layer delivers standalone value and is designed so the layers above slot in
without rework.

---

## Layers in detail (reuse vs. new)

### L0 — Isolation tier (seam SHIPPED, runtimes deferred)

- **Decision:** isolation is split into two separable costs — the **abstraction**
  (cheap, painful to retrofit) and the **runtimes** (heavy, per-host infra). Build
  the abstraction now; implement runtimes incrementally.
- **Shipped (seam):** an `isolation_tier` dimension on the agent deployment
  (`native | gvisor | kata | firecracker | vm`, default `native`), threaded
  through the fleet deploy path → maps to a Docker `--runtime` / K8s
  `RuntimeClass`. Always declared, even when `native`. See
  `System::IsolationTier` (`TIERS` map: runtime + strength + overhead +
  host requires) and the `system_list_isolation_tiers` MCP action; selected via
  `isolation_tier` inside a `fleet_spec` (`system_launch_agent_fleet`).
- **Deferred (runtimes):** `gvisor` (runsc + containerd shim) as the first real
  tier when untrusted agents arrive; `kata`/`firecracker` microVMs later for
  stronger boundaries. The seam already records the runtime selection so these
  light up without re-plumbing.
- **Reuse:** `NodeInstance.config` profile pattern; Docker/K3s provisioning.

### L1 — Shared GPU inference *(SHIPPED)*

- **Reuse:** GPU capability on instances (`gpu_count/gpu_type/gpu_memory_mb`,
  `system_find_node_with_gpu`, `system_list_instance_types_by_gpu` — `provider_instance_type.rb` /
  `node_instance.rb`); `NodeModule` + `ModuleService` (exposed_ports + health);
  `ServiceDiscoveryComposer` (SDWAN VIP + `ServiceOffering` + subscriber Traefik
  routes); ollama `Ai::Provider` + `Ai::ProviderClientService` (full chat/stream
  client, `OLLAMA_API_ENDPOINT`).
- **Shipped:**
  - GPU SKU columns on `system/provider_instance_type` (migration
    `20260602150000`) + GPU fields on `NodeInstance`.
  - `gpu-nvidia-runtime` module (nvidia driver + container toolkit) — subscription seed.
  - `inference-ollama` module (ollama binary + `ModuleService` exposing :11434,
    health-checked; `config`: runtime/model/vram_required; depends-on GPU module) — seed.
  - `system_deploy_inference_server` MCP action + `System::InferenceDeploymentService`:
    pick a GPU node (`system_find_node_with_gpu`) → assign both modules →
    `service_discovery_compose` (VIP + offering) → register/point an ollama
    `Ai::Provider` at the VIP endpoint.

### L2 — Agent / MCP runtime (hybrid) *(SHIPPED)*

- **Reuse:** `agent-peering` (`System::NodeInstancePeer.announce!` —
  declared_skills + capabilities + handle + trust_score); `ModuleSkillRegistrar`
  (manifest `skills` → `Ai::Skill`); the platform MCP server
  (`Api::V1::Mcp::StreamableHttpController`).
- **Shipped:**
  - Instances run an MCP server and/or agent worker via the fleet deploy path;
    **hybrid** — uniform peers with declared capabilities.
  - **Instance MCP principal:** the core `Mcp::Principal` (parent
    `server/app/models/mcp/principal.rb`) is **default-deny**; an instance's
    allowed tools are recorded in `granted_mcp_tools` on `NodeInstancePeer`
    (migration `20260602160000`) and granted via the `system_grant_instance_mcp_tools`
    MCP action. The instance authenticates by its **mTLS identity**
    (`MtlsClientVerifier`, CN → instance), binding a scoped session.
  - **Scoped catalog:** `tools/list` is filtered to the instance's granted subset
    (the `concierge_tool_filter` pattern). An instance calling `tools/list` over
    its mTLS session receives only its allowed tools.

### L2½ — A2A mesh (instance↔instance MCP over mTLS) *(SHIPPED)*

- **The key reuse:** this is the **federation mTLS pattern applied intra-account,
  instance-to-instance** — but simpler: one **shared account CA** (not two), so
  it's the `MtlsClientVerifier` "verify against our CA + map CN → instance" path.
- **Transport (on-node A2A MCP, `agent/internal/a2a/`):** a full MCP JSON-RPC 2.0
  server (`initialize` / `tools/list` / `tools/call`) behind mTLS
  (`RequireAndVerifyClientCert`, default-off via `Config.A2AListenAddr`). Each call
  carries a **signed Ed25519 capability token** in `Authorization: Bearer` —
  minted by `System::PeerCapabilityTokenSigner` (envelope `{sub, aud, skill, exp,
  jti}`, Vault-held key, never logged — *not* a JWT), advertised at
  `node_api/a2a/capability_keys`. Minting happens **server-side only**, in two
  places, neither of which returns the token to its caller:
  `System::AgentFleetMissionService#mint_delegation_token` mints the
  **cross-instance** edge and packages it into the delegation descriptor
  (reached via `system_launch_agent_fleet`), and
  `POST /api/v1/system/node_instance_peers/:id/execute` mints a **self-edge**
  token (caller == target, the peer running its own offered skill) into the
  dispatched `System::Task`. The `system_mint_peer_capability_token` MCP action
  now refuses unconditionally (IMP-27cc7dceb97b): a tool result is persisted
  with the conversation and forwarded to the model provider, so the
  envelope+signature pair cannot ride it. `system_authorize_peer_call` answers
  the policy question with no secret. The agent verifier checks `aud == self`,
  `sub == mTLS CN`, and `skill == tool`.
- **Authorization — three gates** (`System::PeerCapabilityService`, default-deny,
  mirrors the federation "trust ≠ authorization" model at the instance layer):
  1. **Caller grant** — caller peer must be granted skill `S`
     (`granted_peer_skills` on `NodeInstancePeer`, migration `20260602170000`,
     set via `system_grant_instance_peer_skills`).
  2. **Target reachable** — target peer must be `enabled` and `online`.
  3. **Target offers** — target must actually offer skill `S`
     (`offered_skill_names`).
- **Discovery:** `system_discover_peers` lists online, operator-enabled peers in
  the account + their offered skills + addresses; discovery does **not** imply
  call permission (the call is still gated by `system_authorize_peer_call`).
- **Status:** built + committed + **live-smoke-passed** (Ruby mint → Go `a2a.Server`
  verified the Ed25519 signature over mTLS and dispatched the call;
  cross-language canonical-JSON interop confirmed). To enable live A2A in prod,
  set `Config.A2AListenAddr` and ensure node certs carry the `serverAuth` EKU.

### L3 — Missions / orchestration *(SHIPPED)*

- **Reuse:** `Ai::Mission` (multi-phase, approval-gated), `Ai::GoalPlan`,
  `SkillCompositionRunner` (per-step execution + output passing), `InstancePool`
  (pre-warmed ephemeral instances + reaper), agent-peering task delegation.
- **Shipped:** `mission_type: "agent_fleet"` + the `system_agent_fleet` mission
  template (`db/seeds/system_agent_fleet_mission_template.rb`) drive a fleet
  through `plan → review [gate] → provision → delegate → aggregate → reap`.
  `System::AgentFleetMissionService` composes the plan; the worker
  `AgentFleetController` self-advances phases (`AiAgentFleet*Job` via the
  `AiAgentFleetPhaseExecution` concern). Launched with `system_launch_agent_fleet`
  (a `fleet_spec` carries the `isolation_tier`); progress via
  `system_agent_fleet_status`. **Live-smoke-passed.**

---

## Key design decisions (firm)

| # | Decision |
|---|----------|
| D1 | **GPU capability** is first-class on instances/SKUs — done (P6). |
| D2 | **Inference** ships as a `NodeModule` + `ModuleService`, published via `ServiceDiscoveryComposer`, consumed via an ollama `Ai::Provider` pointed at the VIP. No new `inference_server` variety yet (subscription module + config is sufficient and needs zero agent changes). |
| D3 | **Instance MCP access** is authenticated by the instance's **mTLS identity** and gated by the core default-deny `Mcp::Principal` (allowed tools in `granted_mcp_tools`), serving a **scoped catalog**. |
| D4 | **Agent taxonomy:** `Ai::Agent` = platform-runtime (in-process, inference via `Ai::Provider`); `System::NodeInstancePeer` = instance-based (runs in the fleet, A2A-reachable, tools-as-skills). Unified at the orchestration layer by capability. |
| D5 | **Deployment density:** thin **containers** (Docker / K3s pods) on powernode-agent-managed hosts — **never VM-per-agent**. Inference is **offloaded to the shared GPU node**, so agent containers carry no model/GPU (tens of MB each). VMs only when an isolation tier later demands it. |
| D6 | **Isolation:** build the **seam now** (`isolation_tier`, default `native`); implement **runtimes incrementally** (gVisor first). |
| D7 | **A2A** = mTLS transport (shared-account-CA via `MtlsClientVerifier`) + signed Ed25519 capability token + three-gate authorization (`PeerCapabilityService`: caller-grant → target-reachable → target-offers), MCP JSON-RPC as payload, riding SDWAN. *(shipped)* |
| D8 | **Hybrid agents** — instances are uniform peers; a given instance can be a tool-server or an agent-worker per mission step. |

---

## Data-model deltas (shipped, by layer)

- **L1:** GPU SKU columns on `provider_instance_type` (`20260602150000`);
  `NodeModule` seeds (`gpu-nvidia-runtime`, `inference-ollama`) + a
  `ModuleService`; ollama `Ai::Provider` record pointed at the discovered VIP; the
  `system_deploy_inference_server` action (registry-routed).
- **L2:** instance MCP auth via mTLS identity + default-deny `Mcp::Principal`;
  `granted_mcp_tools` on `NodeInstancePeer` (`20260602160000`) + scoped catalog
  filter; `NodeInstancePeer` carries its MCP endpoint address.
- **L0 seam:** `isolation_tier` dimension + runtime-class mapping
  (`System::IsolationTier`).
- **A2A:** `granted_peer_skills` on `NodeInstancePeer` (`20260602170000`);
  `system_peer_capability_signing_keys` Ed25519 key (`20260602180000`).
- **L3:** the `system_agent_fleet` mission template + runner steps for fleet
  provision/delegate/reap.

---

## Phased roadmap

| Phase | Layer | Deliverable | Status |
|-------|-------|-------------|--------|
| **1** | L1 | GPU + ollama modules; `system_deploy_inference_server`; ollama `Ai::Provider` wired to the VIP | **Shipped** — specs + `db:seed`; smoke against DNA's real ollama via the existing provider (no DNA changes); simulated GPU node for the deploy/expose path |
| **2** | L0-seam + L2 | `isolation_tier` dimension; instance MCP mTLS auth + default-deny `Mcp::Principal` + scoped catalog | **Shipped** — instance `tools/list` over mTLS returns the granted subset |
| **3** | L2½ | A2A: instance↔instance MCP over mTLS; signed capability token; grant/discover/authorize | **Shipped** — live-smoke-passed (Ruby mint → Go verify over mTLS, cross-language Ed25519 interop) |
| **4** | L3 | mission-driven dynamic agent fleet (provision → delegate → coordinate → reap) | **Shipped** — `system_agent_fleet` mission live-smoke-passed |
| later | L0 / — | gVisor/microVM **runtimes**; WASM module variety; model-artifact registry + versioning; skill A/B + self-improvement loop; confidential compute (SEV/TDX) | **Deferred** — maps to the remaining 2026-06 audit ai-substrate gaps |

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
- ~~Instance MCP auth: mTLS arm vs scoped Doorkeeper tokens.~~ **Resolved (L2):**
  mTLS identity + default-deny `Mcp::Principal` (`granted_mcp_tools`); no token
  distribution.
- ~~A2A grant granularity: per-tool vs per-capability-set.~~ **Resolved (L2½):**
  per-skill, default-deny (`granted_peer_skills` + the three-gate
  `PeerCapabilityService`).
- Ephemeral vs persistent agents: pools for dynamic/mission agents; persistent for
  long-lived tool-servers.
- Whether to add a `runtime` discriminator/bridge on `Ai::Agent` for a single
  unified agent list (sugar; not required — taxonomy is already structural).

---

_Last verified: 2026-06-03_
