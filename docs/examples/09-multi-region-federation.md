# Example 09 — Multi-region federation peer (slice 11, in active sweep)

End-to-end walkthrough: Account A in `us-east-1` proposes a federation peer with Account B in `ap-tokyo-1`, allowing controlled cross-account SDWAN traffic. **Markdown-only example** — gated on slice 11 acceptance flow which is in active sweep as of 2026-05-04.

**Status:** ◐ Partial — propose / list / revoke flows shipped; acceptance UI not yet wired.

**Goal:** demonstrate cross-account / cross-region overlay topology for federated workloads.

**Audience:** multi-region platform operators, partners building cross-org integrations.

## When this works (and doesn't)

| Capability | Status | Notes |
|---|---|---|
| Account A proposes federation with Account B | ✅ Works | `system_sdwan_propose_federation_peer` |
| List existing federation peers (proposed + accepted) | ✅ Works | `system_sdwan_list_federation_peers` |
| Account B accepts the proposal | ❌ Not yet (slice 11) | Blocked on UI + cross-account auth flow |
| Cross-account routing once accepted | ❌ Not yet | Requires the acceptance flow first |
| Revoke an existing federation | ✅ Works | `system_sdwan_revoke_federation_peer` |
| Federation peer scan (find proposed-but-unaccepted) | ✅ Works | `system_sdwan_federation_scan` |

## Prerequisites

- Account A with an `Sdwan::Network` in region `us-east-1`
- Account B with an `Sdwan::Network` in region `ap-tokyo-1`
- Both accounts have at least one publicly-reachable peer (hub) — required for federation traffic to traverse provider boundaries
- An accepted partner agreement / mutual trust between the two accounts (out-of-band)

## Step 1 — Account A proposes

```javascript
// Logged in as Account A admin:
platform.system_sdwan_propose_federation_peer({
  network_id: "<account-a-network-id>",
  remote_account_id: "<account-b-id>",
  remote_network_id: "<account-b-network-id>",
  proposed_routes: [
    { remote_prefix: "fd00:abcd:2::/64", local_prefix: "fd00:abcd:1::/64" }
  ],
  proposed_capabilities: ["bgp_announce", "vip_failover"]
})
// → { federation_peer: { id, status: "proposed", ... } }
```

The `FederationPeer` row is created in `status: "proposed"`. Account B sees it on next sync.

## Step 2 — Account B reviews (manual until slice 11)

> **Slice 11 status:** UI for accepting federation proposals is being built. Until it ships, acceptance is via direct DB update or via `system_sdwan_accept_federation_peer` (also pending implementation per `project_system_mcp_gaps`).

Workaround for drills:

```sql
-- As Account B admin, with care:
UPDATE sdwan_federation_peers
SET status = 'accepted', accepted_at = NOW()
WHERE id = '<federation-peer-id>'
  AND remote_account_id = '<account-a-id>';
```

Once accepted, both accounts see the peer transition to `status: "accepted"`.

## Step 3 — Verify routes propagate

After acceptance, the federation peer's routes are advertised over iBGP:

```javascript
platform.system_sdwan_get_routing_summary({ network_id: "<account-a-network-id>" })
// → {
//      static_routes: [...],
//      bgp_routes: [
//        { prefix: "fd00:abcd:2::/64", next_hop: "fd00:abcd:1::ff", source: "federation:account-b" }
//      ],
//      ...
//    }
```

## Step 4 — Apply firewall rules at the federation boundary

Federation traffic should be tightly controlled:

```javascript
// Default deny all traffic from federation peers
platform.system_sdwan_create_firewall_rule({
  network_id: "<account-a-network-id>",
  direction: "ingress",
  action: "drop",
  selector: { kind: "federation_peer", federation_peer_id: "<id>" },
  protocol: "any"
})

// Explicit allow for the agreed services only
platform.system_sdwan_create_firewall_rule({
  network_id: "<account-a-network-id>",
  direction: "ingress",
  action: "accept",
  selector: { kind: "federation_peer", federation_peer_id: "<id>" },
  protocol: "tcp",
  port_range: "443"
})
```

## Step 5 — Use the federated network

Once accepted + routes converged + firewall configured:

```bash
# From an Account A peer, reach an Account B peer's /128
curl -k https://[fd00:abcd:2::42]/healthz
# → response from Account B's service
```

## Step 6 — Revoke when done

```javascript
platform.system_sdwan_revoke_federation_peer({ id: "<federation-peer-id>" })
// → status: "revoked"; routes withdrawn from BGP; firewall rules unaffected (operator must clean up)
```

## What to watch

- **Cross-account auth at acceptance time** is the slice 11 blocker — Account B needs to confirm Account A's identity without sharing operator credentials
- **Trust boundary asymmetry** — once federated, Account A sees a route into Account B's network; Account B doesn't automatically reciprocate. Use bilateral propose/accept for symmetric topologies.
- **Route propagation depth** — with 3+ federation peers, BGP path selection becomes non-trivial; use `system_sdwan_create_route_policy` to constrain advertisement
- **Until slice 11 lands:** for drills + experimentation, document the manual SQL-based acceptance workaround in your team's runbook

## Related

- [`runbooks/sdwan-network-setup.md`](../runbooks/sdwan-network-setup.md) §Phase 9 — federation reference
- [`MCP_API_REFERENCE.md`](../MCP_API_REFERENCE.md) §`system_sdwan_*` — full federation action catalog
- [`example 02`](./02-k3s-cluster-with-sdwan.md) — single-region precursor
- Memory `project_sdwan_routing_state` — slice 9 a–f complete; slice 11 in active sweep
