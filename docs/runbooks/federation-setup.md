# Federation Setup — Quick Start

Get two Powernode platforms federated in ~5 minutes. This runbook covers the **happy path** for proposing → accepting → activating a federation peer. For failure modes, see [`federation-troubleshooting.md`](./federation-troubleshooting.md).

For the underlying protocol (sovereign auth model, social contract, three spawn modes), see the federation reference docs:
- [`../federation/SPAWN_MODES.md`](../federation/SPAWN_MODES.md) — `managed_child` / `autonomous_peer` / `cluster_member`
- [`../federation/SOCIAL_CONTRACT.md`](../federation/SOCIAL_CONTRACT.md) — the 12-commitment framework
- [`../federation/NETWORK_TRUST.md`](../federation/NETWORK_TRUST.md) — cryptographic trust model

---

## What you'll do

For two operators — call them **A** and **B** — running independent Powernode platforms:

1. **A** proposes federation with B's platform → gets back an acceptance token
2. **A** shares the token + their platform URL with B (out of band: Signal, password manager, etc.)
3. **B** accepts using the token → peer record on B's side flips to `accepted`
4. The first successful heartbeat between them advances the state machine to `active`
5. Either side can now offer/subscribe to services through the federation surface

At the end, both A's and B's platforms have a `System::FederationPeer` row for each other, each in `peer_kind: "platform"` + `status: "active"`.

---

## Prerequisites

- Both platforms reachable from each other (no NAT issues; each platform's `remote_instance_url` resolves from the other side)
- An operator account on each side with the `system.federation_peers.manage` permission (defined by the system extension)
- (Recommended) An out-of-band secure channel — Signal, 1Password share, in-person — for token handoff

If your platform is behind NAT or you're peering with a sovereign on-prem satellite, see [`SPAWN_MODES.md`](../federation/SPAWN_MODES.md#nat-traversal) for the host-bridge + UPnP options.

---

## Step 1 — A: Propose the peer

On **A**, propose a federation with B. From the operator UI: **Network → Federation → Propose Peer**. Or via MCP:

```
platform.system_sdwan_propose_federation_peer
  remote_instance_url: "https://platform-b.example.com"
  peer_kind: "platform"
  spawn_role: "symmetric"
  description: "Peering with Org B for shared SDWAN + service catalog"
```

This creates a `System::FederationPeer` row on A's side with `status: "proposed"`. It does **not** contact B yet.

---

## Step 2 — A: Generate an acceptance token

The peer record needs a single-use token that B will present when accepting. Generate it:

```ruby
# rails console (on A)
peer = System::FederationPeer.find_by(remote_instance_url: "https://platform-b.example.com")
token = peer.generate_acceptance_token!(ttl_seconds: 7.days.to_i)
puts token
# => fbazXyZ123abc456... (urlsafe-base64, 32 bytes of entropy)
```

The plaintext token is shown **exactly once** here — copy it now. Only its SHA-256 digest is persisted (`acceptance_token_digest` column).

The default TTL is **7 days**. You can pass a shorter `ttl_seconds:` if you're handing it off immediately (`1.hour.to_i`) or want a tighter window.

---

## Step 3 — A → B: Hand off the token

Share with B, out of band:
- A's platform URL (the `remote_instance_url` they'll register: `https://platform-a.example.com`)
- The plaintext token from step 2
- (Optional) The contract version A is operating under — defaults to the current platform-wide default

Don't drop the token into a shared Slack channel; it grants peer enrollment on A.

---

## Step 4 — B: Accept the peer

On **B**, accept using the token A shared. From the operator UI: **Network → Federation → Accept Peer**. Or via MCP:

```
platform.system_sdwan_accept_federation_peer
  remote_instance_url: "https://platform-a.example.com"
  acceptance_token: "<token from A>"
  spawn_role: "symmetric"
```

The accept flow:
1. B's API creates its own `System::FederationPeer` row pointing at A
2. B calls A's `POST /api/v1/system/federation_api/accept` with the token
3. A's `AcceptController` verifies the token against the stored digest (SHA-256 secure_compare)
4. If valid, A's peer row transitions `proposed → accepted` and the token digest is cleared (single-use)
5. B's peer row transitions `proposed → accepted` on success response

**Verify the accept landed on both sides:**

```bash
# On A
curl -s -H "Authorization: Bearer $JWT_A" http://localhost:3000/api/v1/system/sdwan/federation_peers \
  | jq '.data[] | select(.remote_instance_url=="https://platform-b.example.com") | {id, status}'
# => { "id": "...", "status": "accepted" }

# On B
curl -s -H "Authorization: Bearer $JWT_B" http://platform-b.example.com/api/v1/system/sdwan/federation_peers \
  | jq '.data[] | select(.remote_instance_url=="https://platform-a.example.com") | {id, status}'
# => { "id": "...", "status": "accepted" }
```

---

## Step 5 — Enrollment + first heartbeat

Once both sides are `accepted`, the next steps are automatic:

1. The `FederationHeartbeatJob` ticks every 60s on each side (declared in `worker/config/sidekiq.yml` under `:federation_heartbeat`).
2. On its first successful heartbeat to the remote peer, the local peer's `record_heartbeat!` transitions `accepted → enrolled → active`.
3. The `last_handshake_at` and `last_heartbeat_at` columns get populated.

Wait ~60s, then verify:

```bash
curl -s -H "Authorization: Bearer $JWT_A" http://localhost:3000/api/v1/system/sdwan/federation_peers \
  | jq '.data[] | {id, status, last_heartbeat_at}'
# => { "id": "...", "status": "active", "last_heartbeat_at": "2026-05-17T13:45:12Z" }
```

If status hasn't advanced past `accepted` after ~3 minutes, see [`federation-troubleshooting.md`](./federation-troubleshooting.md#peer-stuck-in-accepted).

---

## Step 6 — (Optional) Issue your first cross-peer grant

Now that the peer is `active`, you can issue a service-subscription grant so B can call A's federation_api/resources endpoints. Example: grant B read-only access to A's nginx module catalog:

```
platform.system_sdwan_create_access_grant
  federation_peer_id: "<B's id on A>"
  remote_subject: "operator@platform-b.example.com"
  resource_kind: "NodeModule"
  permission_scopes: ["read"]
  # Optional pessimistic scope (Locked Decision #12)
  node_instance_ids: []   # empty = unrestricted on this axis
  sdwan_network_ids: []
  source_cidrs: []        # empty = any source IP
```

The grant returns a bearer token (`fg-<grant_id>`) that B presents alongside its mTLS cert when calling A's federation_api. Default TTL is 30 days; the grant validates well-formed array contents (UUIDs, CIDRs) on save (LD #12).

---

## Skill-driven accept (acceptance orchestration)

Steps 4–5 above describe the **operator-on-B-runs-the-MCP-action** path.
There is a second path: completing the accept as an **approval-gated skill**,
so the System Concierge (operator chat) or the SDWAN Manager autonomy loop
can finish a peering whose acceptance token the platform holds.

Both paths run the **same** orchestration —
`System::Federation::FederationAcceptanceService` — which owns the full
accept chain. Phase 3 extracted it so the HTTP endpoint, the skill, and any
future re-accept flow share one implementation. The chain:

```
verify contract_version  (HARD — abort 422 if unsupported)
  → locate peer by token digest  (HARD — abort 401 if not found / expired)
  → peer.accept!  (HARD — token round-trip)
  → peer.enroll!  (HARD, platform peers — capabilities + extensions + endpoints)
  → ensure managed_child operator grant  (idempotent)
  → issue node_api bootstrap token  (HARD, managed_child spawns)
  → SDWAN attach  (SOFT — PeerEnroller + bridge activate!)
  → federation governance scan  (SOFT — cert/drift/prefix findings)
```

**HARD** steps abort the whole accept on failure. **SOFT** steps (SDWAN
attach, governance scan) are collected as warnings — the accept still
succeeds with the peer enrolled, and you can re-run the soft step
independently later.

Run it via the Concierge ("accept the federation peer using token `<X>`,
contract version 1") or directly as the skill:

```
platform.execute_agent   # or via Concierge chat
  agent: "SDWAN Manager"
  skill: "federation_acceptance"
  inputs:
    acceptance_token: "<token from the proposing side>"
    contract_version: 1
    # optional forward-compat fields:
    capabilities: {}
    extension_slugs: []
    endpoints: []   # [{ url, scope, priority, cidr_hint? }]
```

Because federation peering is sensitive, the skill is
**approval-gated** (`requires_approval: true`) — it lands in the approval
queue and must be approved before the chain runs. The result returns
`peer_id`, `status`, `contract_version_agreed`, the `node_enrollment` block
(for managed-child spawns), the `sdwan_attach` result, the `governance`
result, and any `warnings`.

> **When to use which:** use the MCP action (Step 4) for plain out-of-band
> peering you're driving by hand. Use the `federation_acceptance` skill when
> you want the accept to flow through the Concierge or the autonomy loop with
> the approval gate — e.g. completing a spawned child's handshake, or
> re-accepting after a transient failure.

For the full architecture of the accept chain (hard/soft steps, the
managed-child grant, the SDWAN attach, governance), see
[`../FEDERATION_MULTI_SITE_GUIDE.md`](../FEDERATION_MULTI_SITE_GUIDE.md) §2.

---

## Step 7 — (Optional) Build the federation overlay topology

Steps 1–6 establish trust between two sites. To carry workload traffic
between them over the encrypted overlay, compose a federation **topology** —
hub-and-spoke or full-mesh — with the `sdwan_federation_compose` skill (bound
to **System Topology Designer**):

```
platform.execute_agent
  agent: "System Topology Designer"
  skill: "sdwan_federation_compose"
  inputs:
    network_name: "fed-overlay-a-b"
    topology: "hub_and_spoke"      # or "full_mesh"
    routing_protocol: "ibgp"        # or "static"
    peers:
      - node_instance_id: "<site-a-hub-instance>"
        role: "hub"                 # hub_and_spoke only; hubs MUST have an endpoint
        endpoint_host_v6: "fd00:abcd:1::21"
        endpoint_port: 51820
      - node_instance_id: "<site-b-instance>"
        role: "spoke"
    dry_run: false                  # set true to preview the fan-out without persisting
```

**Topology choice:**
- **`hub_and_spoke`** — peers behind NAT funnel through a publicly-reachable
  hub. At least one peer must be `role: "hub"` and every hub **must** carry an
  endpoint (`endpoint_host_v6`/`v4` + `endpoint_port`) — the skill fails fast
  otherwise.
- **`full_mesh`** — any-to-any direct connectivity; no hub/spoke distinction.
  Best for low-RTT peers needing direct reachability.

`routing_protocol: "ibgp"` enables FRR route-policy distribution between
peers; `static` emits no FRR policy. Use `dry_run: true` first to review the
projected peer/hub counts and step list before building.

See [`../FEDERATION_MULTI_SITE_GUIDE.md`](../FEDERATION_MULTI_SITE_GUIDE.md) §3
for the topology composition internals and the choose-a-topology decision tree.

---

## Step 8 — (Optional) Isolate a tenant on the overlay

To give one tenant a fully-segregated network slice (its own VRF, /64,
firewall, and OVN ACLs) inside the account — entirely SDWAN-native, no k8s
NetworkPolicy or VLAN — use the `multi_tenant_isolation` skill (bound to
**System Topology Designer**, approval-gated):

```
platform.execute_agent
  agent: "System Topology Designer"
  skill: "multi_tenant_isolation"
  inputs:
    tenant_key: "acme-prod"          # slug-safe; names the network, rules, switch, ACLs
    # tenant_cidr omitted ⇒ the auto-allocated /64 is used (recommended)
    # nb_db_endpoint / sb_db_endpoint required only if the account has no OvnDeployment yet:
    nb_db_endpoint: "tcp:127.0.0.1:6641"
    sb_db_endpoint: "tcp:127.0.0.1:6642"
    dry_run: false
```

What it builds (composed from existing SDWAN services, IDs threaded inline):

1. A dedicated `Sdwan::Network` (`routing_protocol: "ibgp"`) → its own VRF +
   isolated RIB (no shared forwarding table with other tenants).
2. A non-overlapping `/64` via `Sdwan::PrefixAllocator` (the tenant's
   blast-radius boundary).
3. nftables firewall rules: allow the tenant's own `/64` (high priority) +
   default-deny wildcard (low priority).
4. An OVN logical switch scoped to the tenant CIDR.
5. OVN ACLs: allow intra-tenant, drop cross-tenant.

Rollback (on failure or teardown) is reverse-order: OVN ACLs → OVN switch →
firewall rules → network. Use `dry_run: true` to see the planned actions
first. Full architecture in
[`../FEDERATION_MULTI_SITE_GUIDE.md`](../FEDERATION_MULTI_SITE_GUIDE.md) §4a.

---

## Step 9 — (Optional) Discover / reach a federated service

A service on one site is reachable from a federated peer over a **stable
overlay VIP** — no public exposure needed when the consumer is another
federated site:

- **`Sdwan::VirtualIp`** — a stable overlay address fronting the backend
  (static single-holder, or anycast multi-holder).
- **BGP advertisement** — the VIP emits a `Sdwan::SubnetAdvertisement`
  (source `virtual_ip`); FRR advertises the prefix into the iBGP fabric, so
  every peer (and federated peer, subject to route policy) learns the route.
- **Traefik route** (only for public consumers) — a hub DNAT port mapping +
  reverse-proxy regen front the VIP on `443`/`80`.
- **External DNS** (only for public names) — `Acme::DnsClient` publishes the
  public A/AAAA/CNAME. This is the **only** non-SDWAN seam in the discovery
  path.

For a single public service, the `expose_service_publicly` skill chains
VIP → port mapping → ACME cert → reverse-proxy regen — see
[`expose-service.md`](./expose-service.md). For federated peer-to-peer
discovery (no public exposure), the VIP prefix is learned across the
federation bridge when route policy permits it. Architecture in
[`../FEDERATION_MULTI_SITE_GUIDE.md`](../FEDERATION_MULTI_SITE_GUIDE.md) §4b.

---

## Spawn-mode variants

The default in this runbook is `spawn_role: "symmetric"` (both sides are equal peers). For asymmetric federations:

- **`managed_child`** — A spawns B as a managed-child satellite (e.g., on-prem edge platform). B's autonomy is bounded by grants A issues.
- **`autonomous_peer`** — Like symmetric but B is a fully sovereign instance that may federate further with C, D, etc.
- **`cluster_member`** — B is joining an existing federation cluster (typically a K3s control plane).

See [`SPAWN_MODES.md`](../federation/SPAWN_MODES.md) for the operator runbook covering each variant — they all use the same accept-token flow above, but the spawn-mode determines downstream behavior.

---

## What's next

- **Understand the full architecture:** [`../FEDERATION_MULTI_SITE_GUIDE.md`](../FEDERATION_MULTI_SITE_GUIDE.md) covers the acceptance orchestration, SDWAN topology, tenant isolation, service discovery, the liveness autonomy loop, and security in depth
- **Subscribe to a peer service:** see the [`Service Catalog`](../federation/MIGRATION_DEVELOPER_GUIDE.md) developer guide
- **Migrate a resource across peers:** see the Migration framework documentation
- **Monitor peer health:** the Fleet Dashboard's federation tab surfaces every peer, current status, and heartbeat freshness. The **liveness autonomy loop** (`FederationPeerLivenessSensor` → `federation_peer_remediate`) automatically probes stale peers over mTLS, degrades unreachable ones, and alerts on cert expiry — see [`../FEDERATION_MULTI_SITE_GUIDE.md`](../FEDERATION_MULTI_SITE_GUIDE.md) §5
- **Pause federation operations** (during maintenance): the SDWAN Manager agent's federation actions are gated by `require_approval` — drain the approval queue or pause the agent per [`SDWAN_MANAGER_AGENT.md`](../SDWAN_MANAGER_AGENT.md#pause--resume--maintenance-window-runbook)
