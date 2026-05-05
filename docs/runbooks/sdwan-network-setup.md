# SDWAN Network Setup Runbook

End-to-end operator guide for the system extension's SDWAN layer: WireGuard-based overlay networks with first-class VIPs, port mappings, firewall rules, route policies, iBGP/FRR routing, and cross-account federation. Covers slices 1–9 (per memory `project_sdwan_routing_state` — slice 9 a–f fully complete; slice 11 federation acceptance in active sweep).

**Audience:** external operators, internal SREs, network engineers configuring multi-region overlays.

## Concept reference

| Concept | What it is | Backing model |
|---|---|---|
| **Network** | An IPv6 overlay (`/64` prefix) — the topology container | `Sdwan::Network` |
| **Peer** | An endpoint on the network — typically a NodeInstance, but also user devices and federation peers | `Sdwan::Peer` |
| **PeerKey** | Active WireGuard keypair for a peer; rotates on `sdwan_peer_remediate` | `Sdwan::PeerKey` |
| **Virtual IP (VIP)** | First-class `/128` address with primary + failover holders (slice 3) | `Sdwan::VirtualIp`, `Sdwan::VirtualIpAssignment` |
| **PortMapping** | Maps an external port → internal `/128:port` for inbound traffic | `Sdwan::PortMapping` |
| **FirewallRule** | nft rule applied per-peer with selectors (peer, tag, cidr) | `Sdwan::FirewallRule` |
| **RoutePolicy** | JSONB statement compiled to FRR route-map + aux objects (slice 9) | `Sdwan::RoutePolicy` |
| **AccessGrant** | Token granting a user the right to add a device to a network | `Sdwan::AccessGrant` |
| **UserDevice** | A WireGuard endpoint authenticated via AccessGrant | `Sdwan::UserDevice` |
| **AccountBgp** | Per-account AS number + BGP global config | `Sdwan::AccountBgp` |
| **BgpSession** | iBGP session between two peers; state machine | `Sdwan::BgpSession` |
| **FederationPeer** | Cross-account peer (slice 11 acceptance flow) | `Sdwan::FederationPeer` |
| **SubnetAdvertisement** | LAN subnet a peer announces over iBGP | `Sdwan::SubnetAdvertisement` |

## Phase 1 — Create an overlay network ✅

```javascript
platform.system_sdwan_create_network({
  name: "tokyo-edge",
  description: "CDN edge fabric across us-east-1 + ap-tokyo-1",
  prefix: "fd00:abcd:1::/64",          // optional; auto-allocated if omitted
  routing_mode: "static",              // "static" | "ibgp"
  pod_subnet_prefix: null              // slice 9: pod traffic routing (future)
})
// → { network: { id, name, prefix, status: "active", ... } }
```

**What to watch:**
- The `prefix` must be unique per account. If omitted, the platform allocates a `/64` from the account's pool.
- `routing_mode: "ibgp"` enables iBGP/FRR (slice 9c). All peers on the network get `bgpd` in their userspace and announce subnets to each other. Use this for multi-region fleets or when you have LAN segments behind peers. Single-FRR-per-host model: only the first iBGP network's `BgpConf` is active per host.
- Don't enable iBGP on a network with <3 peers — overhead outweighs benefit.

## Phase 2 — Attach NodeInstance peers ✅

```javascript
platform.system_sdwan_attach_peer({
  network_id: "<network-id>",
  node_instance_id: "<instance-id>",
  // Optional:
  publicly_reachable: true,            // hub vs spoke; auto-detected by default
  endpoint_address: "203.0.113.5:51820"  // override agent's auto-detect
})
// → { peer: { id, public_key, host_address: "fd00:abcd:1::42", ... } }
```

The platform allocates a `/128` from the network's `/64`, generates a server-side WireGuard keypair (Sdwan::PeerKey), and waits for the agent's next reconcile to apply the config locally.

**Verify:**

```javascript
platform.system_sdwan_list_peers({ network_id: "<network-id>" })
// → { peers: [{ id, status: "handshake_pending"|"connected", last_handshake_at, ... }] }
```

Status transitions:
- `handshake_pending` → agent hasn't picked up config yet (next reconcile, ~30 s)
- `handshaking` → wg interface up, awaiting handshake
- `connected` → handshake completed; `last_handshake_at` set
- `silent` → no handshake in 5 min; `sdwan_reachability_sensor` fires

**Common failures:**
- `EndpointUnreachableError` — peer's NAT punching failed. Set `publicly_reachable: true` on at least one hub peer (the rest connect outbound through it).
- `KeysOutOfSync` — agent applied stale config. Run `sdwan_peer_remediate` skill to rotate keys + force re-handshake.

## Phase 3 — Allocate Virtual IPs (slice 3) ✅

VIPs provide stable addresses that survive peer failover:

```javascript
platform.system_sdwan_create_virtual_ip({
  network_id: "<network-id>",
  name: "k3s-api",
  primary_holder_peer_id: "<peer-id-of-k3s-server-bootstrap-node>",
  failover_holder_peer_ids: ["<peer-id-of-k3s-server-2>", "<peer-id-of-k3s-server-3>"],
  anycast: false                       // false = single-holder; true = anycast
})
// → { virtual_ip: { id, address: "fd00:abcd:1::100", primary_holder_peer_id, ... } }
```

When the primary holder goes silent (`sdwan_vip_reachability_sensor` fires `sdwan.vip_holder_silent`), `sdwan_vip_failover` skill (require_approval policy) promotes the next failover candidate. The address doesn't change — kubectl + workers' `K3S_URL` keep working through the transition.

**Anycast VIPs** (`anycast: true`) skip failover — multiple holders all serve the address simultaneously; routing converges to closest.

**Verify failover:**

```javascript
platform.system_sdwan_failover_virtual_ip({
  virtual_ip_id: "<vip-id>",
  // Optional: explicit target peer; otherwise picks highest-scored candidate
  target_peer_id: "<peer-id>",
  dry_run: true                        // preview the failover without committing
})
// → { resolved: false, previous_holder: ..., new_holder: ..., dry_run: true }
```

**Anti-pattern:** single-server K3s clusters cannot use VIP failover — slice 3 requires ≥2 servers. The VIP exists but failover is no-op when only one candidate remains.

## Phase 4 — Port mappings (inbound traffic) ✅

For traffic entering the overlay from outside:

```javascript
platform.system_sdwan_create_port_mapping({
  network_id: "<network-id>",
  external_address: "203.0.113.5",      // public IP of a hub peer
  external_port: 443,
  internal_peer_id: "<target-peer-id>",
  internal_port: 8443,
  protocol: "tcp"
})
// → { port_mapping: { id, ... } }
```

The hub peer's nftables ruleset is updated; traffic to `203.0.113.5:443` rewrites to `[<target-peer-/128>]:8443` over the encrypted overlay.

**What to watch:**
- The hub peer must be `publicly_reachable: true` and have a routable external IP.
- For Kubernetes Ingress, prefer a VIP over a port mapping — VIPs survive peer failover; port mappings don't.

## Phase 5 — Firewall rules ✅

```javascript
platform.system_sdwan_create_firewall_rule({
  network_id: "<network-id>",
  direction: "ingress",                 // "ingress" | "egress" | "both"
  action: "accept",                     // "accept" | "drop" | "reject"
  selector: {
    kind: "peer",                       // "peer" | "tag" | "cidr" | "all"
    peer_id: "<source-peer-id>"         // when kind=peer
  },
  protocol: "tcp",                      // "any" | "tcp" | "udp" | "icmp6"
  port_range: "8443"                    // optional; "8443-8480" for ranges
})
// → { firewall_rule: { id, ... } }
```

Compiled to nft on the holding peer. Rule order: more specific selectors win (peer > tag > cidr > all).

**Examples:**

```javascript
// Allow tenant-A pods to reach tenant-A's database VIP only
platform.system_sdwan_create_firewall_rule({
  network_id: net,
  direction: "ingress",
  action: "accept",
  selector: { kind: "tag", tag: "tenant-A" },
  protocol: "tcp",
  port_range: "5432"
})

// Default-deny everything else to that VIP
platform.system_sdwan_create_firewall_rule({
  network_id: net,
  direction: "ingress",
  action: "drop",
  selector: { kind: "all" },
  protocol: "tcp",
  port_range: "5432"
})
```

## Phase 6 — Route policies (slice 9) ✅

Route policies shape iBGP advertisements when `routing_mode: "ibgp"`. Statements compile to FRR `route-map` + auxiliary `prefix-list` / `as-path-list` / `community-list`:

```javascript
platform.system_sdwan_create_route_policy({
  network_id: "<network-id>",
  name: "prefer-tokyo-via-aggregator",
  direction: "import",                  // "import" | "export"
  statements: [
    {
      seq: 10,
      match: { prefix: "fd00:abcd:1:cafe::/96", peer: "<tokyo-aggregator-peer-id>" },
      set: { local_pref: 200 },
      action: "permit"
    },
    {
      seq: 20,
      match: { prefix: "fd00:abcd:1:cafe::/96" },
      action: "permit",
      set: { local_pref: 100 }            // lower preference for non-aggregator paths
    }
  ]
})
```

The compiler emits FRR config to each peer's `/etc/frr/frr.conf` on next reconcile. To audit existing policies:

```javascript
platform.system_sdwan_list_route_policies({ network_id: "<network-id>" })
```

The `system.sdwan_route_policy_audit` autonomy action (auto_approve policy) periodically surfaces inconsistent or shadowed statements.

## Phase 7 — User devices (WireGuard VPN) ✅

For human operators connecting from laptops/phones:

```javascript
// Step 1: create an access grant (single-use bootstrap URL)
platform.system_sdwan_create_access_grant({
  network_id: "<network-id>",
  device_name_hint: "alice-laptop",
  expires_in_seconds: 900                 // 15 min default
})
// → { access_grant: { id, bootstrap_url: "https://platform/.../bootstrap?token=...", expires_at } }

// Step 2: user opens bootstrap URL → returns WireGuard config
//   (operator UI generates QR code for mobile)

// Step 3: issue device after user setup
platform.system_sdwan_issue_user_device({
  network_id: "<network-id>",
  access_grant_id: "<grant-id>",
  public_key: "AbCd...="                  // user's WireGuard public key
})
// → { user_device: { id, host_address: "fd00:abcd:1::200", status: "active" } }
```

**Revoke:**

```javascript
platform.system_sdwan_revoke_user_device({ user_device_id: "<id>" })
// → device removed from network's wg config on next reconcile
```

`system.sdwan_user_device_revoke` is `require_approval` (cuts off a user) — the autonomy executor never runs this without operator approval.

## Phase 8 — iBGP / FRR routing (slice 9c) ✅

When `routing_mode: "ibgp"` is set on a network, peers exchange routes via iBGP. Configure the per-account ASN once:

```javascript
platform.system_sdwan_set_account_as_number({
  as_number: 65000                         // private-range ASN; 64512–65534
})
```

Each peer announces its assigned subnets:

```javascript
platform.system_sdwan_set_peer_lan_subnets({
  peer_id: "<peer-id>",
  subnets: [
    { prefix: "fd00:abcd:1:1::/64", description: "Tokyo office LAN" }
  ]
})
```

The platform creates `Sdwan::SubnetAdvertisement` rows; the peer's FRR config gets a matching `network` statement; routes propagate via iBGP to all other peers on the network.

**Verify session health:**

```javascript
platform.system_sdwan_get_bgp_sessions({ network_id: "<network-id>" })
// → { sessions: [{ peer_id, neighbor_id, state: "Established"|"Idle"|..., uptime, ... }] }
```

States: `Idle → Connect → Active → OpenSent → OpenConfirm → Established`.

**Troubleshooting unhealthy sessions:**

```javascript
// Run the planning-only triage skill
platform.execute_skill({
  skill: "system-sdwan-bgp-session-remediate",
  inputs: { bgp_session_id: "<session-id>", dry_run: true }
})
// → { state: "idle", likely_cause: "...", recommended_action: "vtysh -c 'clear ip bgp <neighbor>'" }
```

The skill is intentionally planning-only in v1 — operators run the recommended `vtysh` command after review.

## Phase 9 — Federation peers (slice 11, in sweep) ◐

Cross-account peering. Account A proposes; Account B accepts. **Acceptance flow gated on slice 11.**

```javascript
// Account A proposes
platform.system_sdwan_propose_federation_peer({
  network_id: "<account-a-network-id>",
  remote_account_id: "<account-b-id>",
  remote_network_id: "<account-b-network-id>"
})
// → { federation_peer: { id, status: "proposed", ... } }

// Account B reviews via UI → accepts (UI not yet wired in slice 11; manual SQL update for now)
// platform.system_sdwan_accept_federation_peer({ id: "<fed-peer-id>" })  // future

// Once accepted, both accounts see the cross-account peer
platform.system_sdwan_list_federation_peers({ network_id: "<network-id>" })
```

**What works today:** propose flow, list, revoke. Acceptance is operator-driven via SQL until slice 11 lands.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Peer stuck `handshake_pending` | Agent didn't pick up config (reconcile not yet fired) | Wait 30 s; or force `systemctl restart powernode-agent` on node |
| Peer stuck `handshaking` | NAT / firewall blocks WireGuard UDP | Make at least one peer `publicly_reachable: true` with port 51820/udp open; others connect outbound through it |
| Peer goes `silent` after working | Connection lost / node rebooted | `sdwan_reachability_sensor` fires `sdwan.hub_unreachable`; `sdwan_failover` skill emits hub-promotion plan |
| BGP session stuck `Idle` | Wrong AS number or unreachable neighbor | Run `sdwan_bgp_session_remediate` skill (planning) → operator runs `vtysh` per recommendation |
| BGP session stuck `Active` | Neighbor doesn't respond to Open message | Verify the neighbor is up + has the route to this peer's `/128`; `sdwan_peer_remediate` if mTLS is the issue |
| VIP failover doesn't promote | `sdwan_vip_failover` blocked by `require_approval` policy | Check approval queue UI; operator approves → executor runs |
| VIP failover marks `anycast: true` | Anycast VIP — failover is informational only | This is expected; routing handles failover for anycast |
| Firewall rule shadows another | Selector specificity — more-specific selectors match first | Use `system.sdwan_route_policy_audit` (auto_approve) to surface shadowed rules |
| User device can't connect after issue | Bootstrap URL expired (>15 min) | Re-issue via `create_access_grant` → `issue_user_device` |

## How the System Concierge should use this

When an operator chats "set up a VPN" / "add a Tokyo edge to our SDWAN" / "kubectl can't reach the cluster":

1. Identify the phase (network creation, peer attach, VIP, firewall, BGP, federation, user device)
2. For each phase, surface the relevant MCP action + required inputs
3. For destructive actions (revoke, failover), use `request_confirmation` before invoking
4. After invoking, watch `last_handshake_at` and BGP `state` transitions; report changes
5. If a sensor fires while the operator is waiting (e.g., `sdwan.hub_unreachable`), surface the relevant skill (`sdwan_failover` / `sdwan_peer_remediate`) for operator approval

## Related docs

- [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — use case 9 explains the pod-traffic-encryption gap
- [`runbooks/multi-cluster-k3s.md`](./multi-cluster-k3s.md) — multi-cluster K3s with slice 3 VIPs for HA
- [`FLEET_SENSORS.md`](../FLEET_SENSORS.md) — `sdwan_reachability_sensor`, `sdwan_drift_sensor`, `sdwan_bgp_session_health_sensor`, `sdwan_vip_reachability_sensor`
- [`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md) — `sdwan_failover`, `sdwan_peer_remediate`, `sdwan_bgp_session_remediate`, `sdwan_vip_failover`
- [`MCP_API_REFERENCE.md`](../MCP_API_REFERENCE.md) — full `system_sdwan_*` action catalog (~70 actions)
