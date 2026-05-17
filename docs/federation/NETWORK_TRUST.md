# Network-Scoped Federation Trust (Locked Decision #12)

How SDWAN routing integrates into federation trust, how pessimistic
grants gate cross-peer access, and what headers the reverse proxy MUST
forward to make the auth chain work.

Plan reference: Decentralized Federation §K + Locked Decision #12.

---

## The trust shape

Federation v1 (pre-K) treated SDWAN as an optional transport. A peer
could federate over public WAN with `endpoints: [{scope: wan, ...}]`
and never join the overlay mesh. Grants were scoped to
`(peer, remote_subject, resource_kind, resource_id, scopes)`.

Locked Decision #12 makes SDWAN a **first-class participant** in trust:

1. Federation handshake includes a **network-bridge negotiation step**
   recorded in `system_federation_network_bridges` (peer × sdwan_network
   with state machine).
2. `FederationGrant` gains three **pessimistic-scope allowlists** —
   `node_instance_ids`, `sdwan_network_ids`, `source_cidrs` — that the
   auth chain enforces.
3. The reverse proxy (Traefik) forwards trust metadata (calling
   instance, SDWAN network, source IP) that the auth chain consumes.

Together: a request is denied unless the calling NodeInstance, the
SDWAN network the request arrived over, AND the source IP all match
the populated allowlists on the grant.

---

## What the reverse proxy must forward

Every federation_api request that crosses the proxy → backend hop
needs three headers set by the proxy (Traefik). The backend trusts
these headers because the proxy → backend hop is itself mTLS-
authenticated against the platform's internal CA.

### `X-Calling-Instance`

The NodeInstance.id of the calling peer's process. Extracted from the
client cert's `URI:` SAN encoded as `powernode://instance/<uuid>`.

Traefik config (sketch):

```yaml
http:
  middlewares:
    extract-instance-from-cert:
      passTLSClientCert:
        info:
          subject:
            sans: true
```

A subsequent middleware (or a Lua plugin) parses the URI SAN and sets
`X-Calling-Instance`. Future hardening: validate the SAN format and
reject any cert without one for federation_api endpoints.

### `X-Sdwan-Network`

The SDWAN network ID the request arrived through. Traefik binds
distinct listeners to distinct SDWAN VIPs at deploy time; each
listener is annotated with the corresponding `Sdwan::Network.id`.
The listener writes the static value as the header.

```yaml
http:
  routers:
    federation-api-on-trusted-overlay:
      rule: "Host(`fd00:trusted::100`) && PathPrefix(`/api/v1/system/federation_api`)"
      service: federation-api-backend
      middlewares:
        - inject-sdwan-network-trusted

  middlewares:
    inject-sdwan-network-trusted:
      headers:
        customRequestHeaders:
          X-Sdwan-Network: "019fab12-3456-7890-abcd-ef0123456789"
```

The backend additionally validates that the supplied network ID
corresponds to an **active** `FederationNetworkBridge` for the calling
peer. Without an active bridge, the network value has no meaning and
the request is denied even if the header is set.

### `X-Forwarded-For`

Standard. The platform reads `request.remote_ip` after Rails resolves
trusted proxies. Configure `config.action_dispatch.trusted_proxies` to
include the proxy's internal address.

---

## Pessimistic-grant matching algorithm

For each populated allowlist on a `FederationGrant`:

```ruby
return forbidden unless grant.applies_to_instance?(request.headers["X-Calling-Instance"])
return forbidden unless grant.applies_to_network?(request.headers["X-Sdwan-Network"])
return forbidden unless grant.applies_to_source_ip?(request.remote_ip)
```

Each predicate:

- Returns `true` when its corresponding allowlist is **empty** (no
  restriction on this axis — preserves v1 back-compat).
- Returns `true` when the supplied value is in the populated allowlist.
- Returns `false` when the allowlist is populated but the supplied value
  is missing or doesn't match.

All three axes are AND-combined. A grant with populated allowlists is
pessimistic: every populated axis must match.

---

## How operators compose pessimistic grants

A typical "very pessimistic" grant for migration of sensitive data:

```ruby
System::FederationGrant.create!(
  account: alice_account,
  federation_peer: bob_peer,
  grantor_user: alice,
  remote_subject: "bob@peer-b",
  resource_kind: "skill",
  resource_id: skill_x.id,
  permission_scopes: %w[read migrate],

  # Pessimistic axes:
  node_instance_ids: [ bob_api_node.id ],     # only this one node may use the grant
  sdwan_network_ids: [ overlay_trusted.id ],  # only over this network
  source_cidrs: %w[fd00:abcd:1234::/48],      # only from this prefix

  expires_at: 30.days.from_now
)
```

A request from `bob_api_node` on `overlay_trusted` from a
`fd00:abcd:1234:*` address: **allowed**.

A request from any of the following: **denied**.
- A different node on bob's peer
- Over a different SDWAN network
- From a source IP outside the declared prefix
- Missing any of the required headers

---

## Bridge state machine

```
proposed ──(accept!)──▶ active ──(suspend!)──▶ suspended
   │                       │                       │
   ▼                       ▼                       ▼
revoked                 revoked                 revoked  (terminal)
```

A bridge is created at federation handshake time in `proposed` state.
Accepting the federation invitation transitions it to `active`. Operator
may `suspend!` to temporarily disable traffic over that bridge without
losing the configuration; resume by transitioning back to `active`.
Revocation is terminal — the bridge must be recreated.

---

## Diagnostic / debugging

If a federation_api call returns 403 with "calling instance not in
grant allowlist," inspect:

```ruby
grant = System::FederationGrant.find_by_bearer_token("fg-<id>")
grant.node_instance_ids   # what's allowed
request.headers["X-Calling-Instance"]   # what was supplied
```

Repeat for network and source IP. The error message includes the
allowlist contents to make this triage straightforward.

---

## Back-compat (grants created before §K)

Grants created before the LD #12 migration ship with all three
allowlists empty. The predicates return `true` for empty allowlists, so
those grants continue to work unchanged.

The FederationManager AI Skill flags grants with all three allowlists
empty AND `admin` or `migrate` permission scope as
`grant_unrestricted_scope` findings — surfacing pre-K grants that
warrant tightening.

---

## See also

- `docs/federation/SOCIAL_CONTRACT.md` — operator commitments (#3 truthful capability, #6 no-undermining)
- `docs/federation/REVERSE_PROXY_GUIDE.md` — Traefik configuration (P2.5 deliverable; this doc supplements it)
- `app/models/system/federation_grant.rb` — `#applies_to_*?` predicates
- `app/models/system/federation_network_bridge.rb` — bridge model + state machine
- `app/controllers/api/v1/system/federation_api/base_controller.rb` — full auth chain
