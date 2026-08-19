# Federation Troubleshooting

> Status: active

When a federation flow doesn't behave as the [setup runbook](./federation-setup.md) describes, this is the diagnosis playbook. Symptoms are listed by what the operator sees; each diagnosis has a fix or escalation path.

For the underlying state transitions, see `System::FederationPeer::V1_TRANSITIONS` in `extensions/system/server/app/models/system/federation_peer.rb` — a plain `status → [allowed next statuses]` Hash guarded by a `transition_allowed?` check (not an AASM state machine).

---

## Symptom: Accept call returns "acceptance_token does not match stored digest"

**What happened:** the token B presented didn't hash to A's `acceptance_token_digest`.

**Common causes:**
1. **Typo** — most common, especially when copying through messaging clients that auto-mangle long strings
2. **Token already used** — accept is single-use; the digest is cleared after first successful match (Phase 11b design)
3. **Token expired** — A's `generate_acceptance_token!` set a TTL (default 7 days); past `acceptance_token_expires_at` the accept refuses

**Fix:**

```ruby
# On A, regenerate (this clobbers any prior token):
peer = System::FederationPeer.find_by(remote_instance_url: "https://platform-b.example.com")
new_token = peer.generate_acceptance_token!(ttl_seconds: 1.hour.to_i)
puts new_token
```

Hand the new token off again. If you're scripting accepts, generate the token then immediately hand it off via a synchronous channel (don't queue it for delivery — TTL races are easy to lose).

---

## Symptom: Accept fails with "acceptance_token required (peer has acceptance_token_digest set)"

**What happened:** B's accept call didn't include the `acceptance_token` parameter at all, but A's peer record requires one.

**Fix:** include the token in the accept call.

- **MCP:** pass `acceptance_token: "..."` to `system_sdwan_accept_federation_peer`.
- **REST:** send it with the accept PATCH, either beside the peer body or inside it:

  ```bash
  curl -X PATCH .../api/v1/system/sdwan/federation_peers/<id> \
    -H 'Content-Type: application/json' \
    -d '{"federation_peer": {"status": "accepted"}, "acceptance_token": "<token from A>"}'
  ```

  Both surfaces verify the token BEFORE parking the approval, so a wrong or
  expired token returns 422 immediately and does not consume the single-use
  token. A correct one returns 202 and the peer flips to `accepted` once the
  approval is granted.

There is no "Accept Peer" UI form — this doc previously said there was. The
federation peer surface has no frontend at all (IMP-8df377f7d255); MCP and REST
are the two ways in.

**Note:** Phase 11a drill-mode peers (no digest set) accept any caller. If you're in a sandbox and want to skip the token round-trip, omit `generate_acceptance_token!` in step 2 of [setup](./federation-setup.md) — but never do this in production.

---

## Symptom: Peer stuck in `accepted`

**What you see:** both sides show `status: "accepted"` indefinitely; never advances to `enrolled` or `active`.

**Root cause:** the `FederationHeartbeatJob` isn't running or its calls aren't reaching the remote peer. The state transition `accepted → enrolled → active` only happens when `record_heartbeat!` fires.

**Diagnose:**

1. **Check the job is registered and the class exists:**
   ```bash
   grep -A3 "federation_heartbeat:" /opt/powernode/worker/config/sidekiq.yml
   ls /opt/powernode/worker/app/jobs/federation_heartbeat_job.rb
   ```
   Both should exist. If the job class is missing, the scheduler logs `NameError: uninitialized constant FederationHeartbeatJob` every 60s.

2. **Check the worker is processing the queue:**
   ```bash
   sudo systemctl status 'powernode-*-sidekiq.service'
   ```
   The worker should be `active (running)`. The federation heartbeat runs on the `system` queue.

3. **Check worker logs for the sweep:**
   ```bash
   journalctl -u 'powernode-*-sidekiq.service' -f | grep -i "FederationHeartbeatJob"
   ```
   You should see `[FederationHeartbeatJob] Starting heartbeat sweep` every 60s.

4. **Check the server-side worker_api endpoint responds:**
   ```bash
   curl -X POST -H "X-Worker-Token: $WORKER_TOKEN" \
     http://localhost:3000/api/v1/system/worker_api/federation/heartbeat_sweep
   # => { "data": { "swept": 0, "degraded_ids": [], "ran_at": "..." } }
   ```
   The endpoint should return 200 with a structured response. 404 → route missing; 500 → check Rails logs.

5. **Check the outbound peer call:**
   The heartbeat sweep calls the local `HeartbeatSweepService` which marks stale peers as degraded — it doesn't directly hit the remote. For peer-initiated heartbeats (the outbound side), look at `Federation::PeerClient` in the rails logs. mTLS partial-config issues will log `[PeerClient] partial mTLS config — cert_pem=true, key_pem=false; falling back to plaintext` (see "mTLS issues" below).

---

## Symptom: Peer flipped to `degraded`

**What you see:** peer was `active`, now `status: "degraded"`. UI surfaces a federation health warning.

**Root cause:** `HeartbeatSweepService` ran and found `last_heartbeat_at` older than `HEARTBEAT_STALE_AFTER` (5 minutes). That happens when:
- Network partition between A and B
- B's platform is down (restart, OS upgrade, etc.)
- B's `federation_api/heartbeat` endpoint is rejecting (auth or rate-limit)

**Diagnose:**

```ruby
# rails console on A
peer = System::FederationPeer.find(peer_id)
puts peer.last_heartbeat_at      # how stale?
puts peer.heartbeat_stale?       # confirms degraded reason
puts peer.metadata["degraded_reason"]  # what the sweeper recorded
```

If the remote is reachable again, the next inbound heartbeat will fire `record_heartbeat!` which transitions `degraded → active`. No operator action needed.

If the degraded state persists >24h and the peer is genuinely gone, suspend the row to stop reconciliation noise:

```ruby
peer.suspend!(reason: "remote platform offline; investigation in progress")
```

---

## Symptom: mTLS partial config warning in logs

**What you see:** `[PeerClient] partial mTLS config — cert_pem=true, key_pem=false; falling back to plaintext` (or the inverse) in Rails logs every time the outbound peer client runs.

**Root cause:** the peer's stored federation identity returned one half of the cert/key pair, not both. The federation **mTLS Phase 2** trust flow normally seals both halves at accept time:
- **Hierarchical (parent↔child / `managed_child`):** the child generates its keypair locally and sends only the CSR in the accept call; `FederationAcceptanceService#sign_federation_csr!` signs it off this platform's internal CA (CN forced to `fed:<peer.id>`), stamps `peer.inbound_subject`, and returns the cert (never the private key) for the child to seal via `Federation::OutboundIdentityService#store_issued!`.
- **Symmetric (peer-of-equals):** `Federation::PeerTrustService` exchanges CA anchors and `OutboundIdentityService.self_issue!` self-issues off the local CA with the CN the peer assigned.

A `partial mTLS config` warning means one of those steps half-completed — e.g. the CSR was signed but the outbound key never sealed locally, or a Vault write dropped one half. (This is now an edge case, not an unbuilt flow — both trust modes ship and are exercised by the live two-platform federation smoke.) The defensive behavior:
- Plaintext request is attempted
- A remote peer enforcing client-cert verification will reject; you'll see `ConnectionError` in the call site
- A peer that accepts plaintext will succeed but unauthenticated

If the remote peer is rejecting, the clean recovery is to **revoke + re-propose** the peer so the accept chain re-runs the trust exchange from scratch and re-seals both halves. For a targeted re-mint, re-run the CSR sign via `System::InternalCaService.issue_certificate(csr_pem: ...)` and re-seal the outbound identity through `Federation::OutboundIdentityService`.

> **Production auth note:** the `child → parent` (hierarchical) direction needs no Traefik trust change because the child's cert chains to the parent's own CA, already in the proxy's client-auth bundle. The symmetric tier uses the two-file Traefik split (`internal-ca.pem` vs `client-auth-bundle.pem` written by `Acme::TraefikConfigWriter`) so federation peers terminate mTLS at the reverse proxy. This is distinct from the `/node_api/*` (on-node agent) surface, where mTLS termination is still forward-compat scaffold and JWT is the operational auth.

---

## Symptom: Grant rejected at remote with "grant scope mismatch"

**What you see:** B calls A's `federation_api/resources/*` with a grant bearer token, gets back a 403 with "scope mismatch".

**Common causes:**
1. **Pessimistic scope (LD #12) doesn't match the calling context** — `applies_to_instance?` / `applies_to_network?` / `applies_to_source_ip?` returned false because B's instance_id / network_id / source IP isn't in the grant's allowlist.
2. **Grant expired** (`expires_at` past)
3. **Grant revoked** (`revoked_at` set)
4. **Permission scope insufficient** — caller needs `write` but grant only has `read` in `permission_scopes`

**Diagnose:**

```ruby
# rails console on A (the grantor side)
grant = System::FederationGrant.find_by_bearer_token("fg-<id>")
puts grant.active?                              # false → expired or revoked
puts grant.permission_scopes                    # ["read"] etc.
puts grant.node_instance_ids                    # empty = unrestricted
puts grant.sdwan_network_ids
puts grant.source_cidrs
puts grant.applies_to?(
  instance_id: "<their instance>",
  sdwan_network_id: "<their network>",
  source_ip: "<their source IP>"
)
```

**Fix:**
- Expired → re-issue a new grant (the v1 grant lifecycle is manual; auto-renewal is on the roadmap)
- Pessimistic scope mismatch → update the grant's allowlists, or issue a new grant scoped to the caller's actual context
- Permission insufficient → revoke + re-issue with broader `permission_scopes`

---

## Symptom: Federation API returns 401 even with valid cert + grant

**What you see:** B presents both an mTLS cert (signed by A's internal CA per the P2.5 flow) and a `Bearer fg-<grant_id>` header, but A returns 401.

**Diagnose order:**
1. **Cert chain valid?** A's `FederationApi::BaseController#authenticate_federation_peer!` walks the cert chain. Use `openssl s_client -showcerts -connect platform-a:443` from B's side to see what cert is being presented.
2. **Cert belongs to a known peer?** The cert's subject CN (`fed:<peer.id>`, assigned by A at accept time) resolves back to the `System::FederationPeer` via `inbound_subject`. If that peer row doesn't exist (or is `revoked` / `suspended`), auth fails.
3. **Grant token parses?** The `Authorization: Bearer fg-<uuid>` token must start with `fg-` and resolve to an existing `FederationGrant` row via `find_by_bearer_token`.
4. **Trust chain mismatch?** In the **hierarchical** mode A signed B's CSR off A's own CA, so B's cert chains to A's CA from A's perspective — no mismatch. In the **symmetric** mode each side trusts the other's advertised CA anchor (`peer.trusted_ca_pem`); if that anchor wasn't absorbed at accept, A validates B's cert against the wrong CA and the chain fails.

**Fix:** revoke the peer and re-propose from scratch so the accept chain re-runs the CSR sign (hierarchical) or CA-anchor exchange (symmetric) and re-stamps `inbound_subject` / `trusted_ca_pem`.

---

## Symptom: `system.federation_peer_*` actions blocked in the approval queue

**What you see:** an operator tried to revoke a peer; the action sat in the `Ai::ApprovalRequest` queue for 4 hours and auto-rejected.

**Root cause:** the SDWAN Manager has `system.federation_peer_revoke` (and `propose`, `accept`) at policy `require_approval` with a 4-hour timeout. Federation actions are sensitive enough that auto-approval is intentionally not allowed.

**Fix:** the action needs to be re-initiated AND approved within the window. Process:
1. Re-issue the revoke/propose via the UI or MCP
2. Visit `/ai/autonomy/approvals` in the operator UI
3. Approve as a user with the `system.infra_tasks.control` permission
4. The SDWAN Manager picks the approval up on its next 60s tick

If you need a faster path for emergency revokes, see [`SDWAN_MANAGER_AGENT.md`](../SDWAN_MANAGER_AGENT.md#tuning-a-policy) for how to temporarily lower the policy. Remember to restore the default after the emergency.

---

## Symptom: `federation_acceptance` skill sits in the approval queue

**What you see:** an operator (or the Concierge) ran the
`federation_acceptance` skill, but nothing happened — the peer never moved
past `proposed`.

**Root cause:** the skill is `requires_approval: true`. It lands in the
`Ai::ApprovalRequest` queue and the accept chain only runs **after**
approval. This is intentional — federation peering establishes trust and is
never auto-approved.

**Fix:**
1. Visit `/ai/autonomy/approvals` in the operator UI.
2. Approve the `federation_acceptance` request (needs the
   `system.infra_tasks.control` permission).
3. The chain runs synchronously on approval (verify token → accept! →
   enroll! → grant → node_enrollment → SDWAN attach → governance scan).

If you'd rather not wait on the queue for a plain out-of-band peering, use
the `system_sdwan_accept_federation_peer` MCP action directly instead — it
runs the same `FederationAcceptanceService` chain without the skill's
approval gate (see [`federation-setup.md`](./federation-setup.md) Step 4 vs
the skill-driven path).

---

## Symptom: accept succeeded but `sdwan_attach` / `governance` reported a warning

**What you see:** the accept returned `status: "accepted"` (or the peer is
`enrolled`/`active`) but the response `warnings` array contains a
`sdwan_attach failed: ...` or `governance[...]: ...` entry.

**Root cause:** the SDWAN attach and governance scan are **soft** steps in
the acceptance chain. A failure there is collected as a warning and the
accept still succeeds with the peer enrolled — the overlay attach and the
health scan can be re-run independently.

**Common `sdwan_attach` outcomes** (none of these are accept failures):
- `status: "skipped", reason: "no_overlay_network"` — the peer has no
  bound SDWAN network (e.g. a plain out-of-band peer). The overlay simply
  isn't part of this peering. Nothing to fix unless you intended an overlay.
- `status: "skipped", reason: "no_bound_instance"` — no
  `node_instance_id` in `peer.metadata`. Expected for out-of-band peers.
- `status: "skipped", reason: "account_mismatch"` — the bound instance
  and the network belong to different accounts. Investigate the spawn
  metadata.
- `status: "error", error: "..."` — a real attach error. Re-run the
  overlay attach by composing the federation topology (see
  [`federation-setup.md`](./federation-setup.md) Step 7) or re-enrolling
  the instance into the network.

**Governance warnings** (`governance[peer_cert_expiring]`, etc.) are
advisory — see the cert-rotation symptom below.

---

## Symptom: peer flapped to `degraded` by the liveness loop (not the sweep)

**What you see:** a peer transitioned `active → degraded`, and the FleetEvent
source is `federation_peer_remediate_executor` (not
`federation_heartbeat_sweep`).

**Root cause:** the **liveness autonomy loop** ran. The
`FederationPeerLivenessSensor` emitted a `system.federation_peer_liveness`
signal (reason `heartbeat_stale`) for a peer whose `last_heartbeat_at`
exceeded `HEARTBEAT_STALE_AFTER` (5 min). The DecisionEngine routed it to
`FederationPeerRemediateExecutor`, which **probed** the peer over mTLS
(`PeerClient#fetch_catalog`); the probe failed (peer unreachable), so it
degraded the active peer with a positive unreachability signal.

This is the loop working as designed — it's faster + more decisive than the
timer-driven sweep because it confirmed unreachability rather than just
observing staleness.

**Diagnose:**

```ruby
# rails console
peer = System::FederationPeer.find(peer_id)
puts peer.status                       # degraded
puts peer.last_heartbeat_at            # how stale
# Check the remediation FleetEvent for the probe error:
```

```
platform.recent_events
  source: "federation_peer_remediate_executor"
  since: <ISO timestamp>
# look for kind "federation.peer.degraded" with the probe error in payload.detail
```

**Fix:** if the remote is genuinely back, its next inbound heartbeat fires
`record_heartbeat!` and the loop's next probe reports `rehandshaked` — the
peer self-recovers `degraded → active`. No operator action. If the remote is
permanently gone, suspend the row:

```ruby
peer.suspend!(reason: "remote site offline; investigation in progress")
```

---

## Symptom: liveness loop keeps `alerting` but never degrades a peer

**What you see:** repeated `federation.peer.unreachable` FleetEvents for a
peer, but its status stays `enrolled` (or already `degraded`) — the loop
alerts but never degrades.

**Root cause:** `mark_degraded!` is gated by the peer state machine — only an
`active` peer can degrade. An `enrolled`-never-came-up peer or an
already-`degraded` peer can't transition, so the executor falls through to
`alerted`. This is correct: the loop never forges a transition the state
machine disallows.

**Fix:** an `enrolled` peer that never reached `active` never completed its
first heartbeat. Diagnose why the first heartbeat never landed — see
[Peer stuck in `accepted`](#symptom-peer-stuck-in-accepted) (the same
heartbeat-job diagnosis applies to the `enrolled → active` transition).
Repeated unreachability past the dedup TTL re-queues, which is the intended
escalation toward an operator `suspend!`.

---

## Symptom: liveness loop alerts `cert_rotation_required` but never rotates

**What you see:** a `federation.peer.cert_rotation_required` FleetEvent
(severity high for expired, medium for expiring) but the federation cert is
never rotated automatically.

**Root cause:** this is intentional. Rotating a federation **trust** cert
requires a cross-CA handshake with the **remote** operator — the local
platform can't unilaterally re-mint a cert the peer's CA must also trust. So
the `federation_peer_remediate` executor only **alerts** for
`cert_expiring` / `cert_expired`; it never silently rotates a trust cert.

**Fix:** coordinate an operator-driven rotation with the remote site:
1. Both operators agree on the rotation window.
2. Re-establish the peer cert via the cross-CA flow (or revoke + re-propose
   the peer for a clean slate — see the mTLS symptom above).
3. The next governance scan clears the `peer_cert_expiring` finding.

---

## Symptom: tenant isolation slice half-built (partial)

**What you see:** the `multi_tenant_isolation` skill returned
`partial: true` with entries in `failures` — some of the network / firewall
/ OVN switch / ACL steps landed but not all.

**Root cause:** the executor composes five steps (network → firewall rules
→ OVN switch → OVN ACLs) and collects per-step failures rather than aborting
at the first one. A `partial: true` means it created *something* but hit a
failure downstream (e.g. an OVN NB DB endpoint was unreachable so the switch
step failed after the network + firewall rules succeeded).

**Diagnose:** read the `failures` array — each entry names the `step` and the
`error`. Common ones:
- `step: "compose_ovn_switch"` with a connection error → the
  `nb_db_endpoint` / `sb_db_endpoint` is wrong or OVN central isn't running.
- `step: "create_firewall_rule"` validation error → a malformed
  `tenant_cidr` (must be a valid v4/v6 CIDR).

**Fix:** the cleanest recovery is to **roll back the partial slice**, fix the
cause, and re-run. The skill's rollback tears down in reverse order (OVN ACLs
→ OVN switch → firewall rules → network), skipping a pre-existing account
OVN deployment. Re-run with corrected inputs (or `dry_run: true` first to
confirm the plan). Architecture: [`../FEDERATION_MULTI_SITE_GUIDE.md`](../FEDERATION_MULTI_SITE_GUIDE.md) §4a.

> **`nb_db_endpoint`/`sb_db_endpoint` required error:** if the skill refuses
> with "required when the account has no Sdwan::OvnDeployment yet," the
> account has never had an OVN deployment. Supply both endpoints so the first
> tenant slice creates it; subsequent slices reuse the one account-level
> deployment automatically.

---

## Symptom: federated peer can't reach a service VIP

**What you see:** Site B can't reach a Site-A service by its overlay VIP,
even though the peer is `active`.

**Diagnose order:**
1. **VIP advertised?** Confirm the VIP emitted a `Sdwan::SubnetAdvertisement`
   (source `virtual_ip`) and FRR is advertising the prefix:
   ```
   platform.system_sdwan_get_routing_summary network_id: "<site-a-network>"
   # bgp_routes should include the VIP's /128 (or /32)
   ```
2. **Route policy permits cross-federation?** The VIP prefix is only learned
   by a federated peer when route policy allows it across the federation
   bridge. Check the route policies on both networks
   (`system_sdwan_list_route_policies`).
3. **Active bridge?** The federation_api auth chain (and route exchange)
   requires an **active** `FederationNetworkBridge` for the (peer, network)
   pair. A `proposed`/`suspended` bridge blocks it.
4. **Holder seated?** A static VIP with no holder peer fronts nothing.
   Confirm the VIP has a holder (`system_sdwan_get_virtual_ip`).

**Fix:** seat a holder if missing, activate the bridge, and add a route
policy permitting the prefix across the federation. For **public** consumers
(not a federated peer), you instead need the Traefik + external-DNS path —
see [`expose-service.md`](./expose-service.md). Discovery architecture:
[`../FEDERATION_MULTI_SITE_GUIDE.md`](../FEDERATION_MULTI_SITE_GUIDE.md) §4b.

---

## Escalation Paths

When the runbook above doesn't resolve the issue:

1. **Check the FleetEvent log for federation events:**
   ```
   platform.recent_events
     source: "federation_heartbeat_sweep"   # or "sdwan_manager", "accept_controller",
                                             # "federation_acceptance_service",
                                             # "federation_peer_remediate_executor"
     since: <ISO timestamp>
   ```
   The accept chain emits `federation.peer.accepted` from
   `federation_acceptance_service`; the liveness loop emits
   `federation.peer.rehandshaked` / `.degraded` / `.unreachable` /
   `.cert_rotation_required` from `federation_peer_remediate_executor`.

2. **Check governance for federation-related findings:**
   The `FederationGovernance` scanner emits findings like `stale_accepted_without_handshake`, `peer_capability_drift`, `overlapping_prefix_advertisement`. Visit the governance dashboard or query `Ai::GovernanceReport`.

3. **Open a code-change request via the Concierge** if the issue is a missing feature (e.g., grant auto-renewal). The Concierge routes to the federation owner.

4. **Pause SDWAN Manager** if reconciliations are making things worse:
   ```ruby
   Ai::Agent.find_by(name: "SDWAN Manager").update!(status: "paused")
   ```

---

## Related Documents

- [`../FEDERATION_MULTI_SITE_GUIDE.md`](../FEDERATION_MULTI_SITE_GUIDE.md) — full architecture (acceptance orchestration, topology, isolation, discovery, liveness loop, security)
- [`federation-setup.md`](./federation-setup.md) — the happy path
- [`../federation/SPAWN_MODES.md`](../federation/SPAWN_MODES.md) — three spawn-mode variants
- [`../federation/SOCIAL_CONTRACT.md`](../federation/SOCIAL_CONTRACT.md) — 12-commitment framework
- [`../federation/NETWORK_TRUST.md`](../federation/NETWORK_TRUST.md) — cryptographic trust model
- [`../SDWAN_MANAGER_AGENT.md`](../SDWAN_MANAGER_AGENT.md) — the agent that gates federation actions
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — system extension architecture reference

_Last verified: 2026-06-03_
