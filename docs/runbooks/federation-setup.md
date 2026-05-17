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

## Spawn-mode variants

The default in this runbook is `spawn_role: "symmetric"` (both sides are equal peers). For asymmetric federations:

- **`managed_child`** — A spawns B as a managed-child satellite (e.g., on-prem edge platform). B's autonomy is bounded by grants A issues.
- **`autonomous_peer`** — Like symmetric but B is a fully sovereign instance that may federate further with C, D, etc.
- **`cluster_member`** — B is joining an existing federation cluster (typically a K3s control plane).

See [`SPAWN_MODES.md`](../federation/SPAWN_MODES.md) for the operator runbook covering each variant — they all use the same accept-token flow above, but the spawn-mode determines downstream behavior.

---

## What's next

- **Subscribe to a peer service:** see the [`Service Catalog`](../federation/MIGRATION_DEVELOPER_GUIDE.md) developer guide
- **Migrate a resource across peers:** see the Migration framework documentation
- **Monitor peer health:** the Fleet Dashboard's federation tab surfaces every peer, current status, and heartbeat freshness
- **Pause federation operations** (during maintenance): the SDWAN Manager agent's federation actions are gated by `require_approval` — drain the approval queue or pause the agent per [`SDWAN_MANAGER_AGENT.md`](../SDWAN_MANAGER_AGENT.md#pause--resume--maintenance-window-runbook)
