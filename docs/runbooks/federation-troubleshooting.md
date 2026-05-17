# Federation Troubleshooting

When a federation flow doesn't behave as the [setup runbook](./federation-setup.md) describes, this is the diagnosis playbook. Symptoms are listed by what the operator sees; each diagnosis has a fix or escalation path.

For the underlying state machine, see `System::FederationPeer::TRANSITIONS` in `extensions/system/server/app/models/system/federation_peer.rb`.

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

**Fix:** include the token in the accept call. From the UI, the "Accept Peer" form has a token field — make sure it's filled. From MCP, pass `acceptance_token: "..."` to `system_sdwan_accept_federation_peer`.

**Note:** Phase 11a drill-mode peers (no digest set) accept any caller. If you're in a sandbox and want to skip the token round-trip, omit `generate_acceptance_token!` in step 2 of [setup](./federation-setup.md) — but never do this in production.

---

## Symptom: Peer stuck in `accepted`

**What you see:** both sides show `status: "accepted"` indefinitely; never advances to `enrolled` or `active`.

**Root cause:** the `FederationHeartbeatJob` isn't running or its calls aren't reaching the remote peer. The state transition `accepted → enrolled → active` only happens when `record_heartbeat!` fires.

**Diagnose:**

1. **Check the job is registered and the class exists:**
   ```bash
   grep -A3 "federation_heartbeat:" /home/rett/Drive/Projects/powernode-platform/worker/config/sidekiq.yml
   ls /home/rett/Drive/Projects/powernode-platform/worker/app/jobs/federation_heartbeat_job.rb
   ```
   Both should exist. If the job class is missing, the scheduler logs `NameError: uninitialized constant FederationHeartbeatJob` every 60s.

2. **Check the worker is processing the queue:**
   ```bash
   sudo systemctl status powernode-worker@default
   ```
   The worker should be `active (running)`. The federation heartbeat runs on the `system` queue.

3. **Check worker logs for the sweep:**
   ```bash
   journalctl -u powernode-worker@default -f | grep -i "FederationHeartbeatJob"
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

**Root cause:** `peer.node_certificate.credentials` returned one half of the cert/key pair, not both. This typically means the federation P2.5 CSR-and-store flow ran partially — the cert was minted and stored but the private key wasn't, or vice versa.

**Fix:** the wiring for full P2.5 cert/key storage is the responsibility of the AcceptController + a forthcoming CSR generation flow (see `accept_controller.rb:28` for the pending TODO). For now, the defensive behavior is:
- Plaintext request is attempted
- A remote peer enforcing client-cert verification will reject; you'll see `ConnectionError` in the call site
- A peer that accepts plaintext (because it's also in pre-P2.5 mode) will succeed but unauthenticated

If the remote peer is rejecting:
1. Manually re-mint and re-store the peer's cert via `System::InternalCaService.issue_certificate(csr_pem: ...)` and store via `peer.node_certificate.store_in_vault(cert_pem: ..., private_key_pem: ...)`
2. Or revoke + re-propose the federation peer (clean slate)

Escalate to the federation P2.5 owner if this is blocking — the cert flow is under active development.

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
2. **Cert belongs to a known peer?** The cert's subject hash maps to a `System::NodeCertificate.id` which maps via `node_certificate_id` to a `System::FederationPeer`. If that peer row doesn't exist (or is `revoked` / `suspended`), auth fails.
3. **Grant token parses?** The `Authorization: Bearer fg-<uuid>` token must start with `fg-` and resolve to an existing `FederationGrant` row via `find_by_bearer_token`.
4. **Trust chain mismatch?** If B presents a cert signed by their CA but A only trusts its own CA, the chain validation fails. The P2.5 flow has A mint certs for B (so they chain to A's CA from A's perspective).

**Fix:** re-run the cert mint flow for that peer. In the meantime, revoke the peer and re-propose from scratch.

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

## Escalation Paths

When the runbook above doesn't resolve the issue:

1. **Check the FleetEvent log for federation events:**
   ```
   platform.recent_events
     source: "federation_heartbeat_sweep"   # or "sdwan_manager", "accept_controller"
     since: <ISO timestamp>
   ```

2. **Check governance for federation-related findings:**
   The `FederationGovernance` scanner emits findings like `stale_accepted_without_handshake`, `peer_capability_drift`, `overlapping_prefix_advertisement`. Visit the governance dashboard or query `Ai::GovernanceReport`.

3. **Open a code-change request via the Concierge** if the issue is a missing feature (e.g., grant auto-renewal). The Concierge routes to the federation owner.

4. **Pause SDWAN Manager** if reconciliations are making things worse:
   ```ruby
   Ai::Agent.find_by(name: "SDWAN Manager").update!(status: "paused")
   ```

---

## Related Documents

- [`federation-setup.md`](./federation-setup.md) — the happy path
- [`../federation/SPAWN_MODES.md`](../federation/SPAWN_MODES.md) — three spawn-mode variants
- [`../federation/SOCIAL_CONTRACT.md`](../federation/SOCIAL_CONTRACT.md) — 12-commitment framework
- [`../federation/NETWORK_TRUST.md`](../federation/NETWORK_TRUST.md) — cryptographic trust model
- [`../SDWAN_MANAGER_AGENT.md`](../SDWAN_MANAGER_AGENT.md) — the agent that gates federation actions
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — system extension architecture reference
