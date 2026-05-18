# P2.5.7 — ACME DNS-01 + LAN-Preference Smoke Runbook

**Acceptance gate** for P2.5 (Reverse Proxy + ACME DNS-01 + Endpoint
Discovery). Run this end-to-end against a `powernode-hub` deployment on
the operator's preferred QEMU host. Expected duration: ~30 min.

For day-2 ACME operator workflow (provider setup, single + multi-SAN
issuance, renewal, revocation, endpoint failover), see the
**[acme-issuance.md](./acme-issuance.md)** runbook.

## Prerequisites

Before starting, gather:

- [ ] **Cloudflare API token** with `Zone:Read` + `DNS:Edit` scoped to a
      test zone you own. (Other DNS providers work too — Hetzner /
      DigitalOcean adapters are in tree; Route53 is stub-only.)
- [ ] **A test domain** in that zone (e.g. `acme-smoke.example.com`).
      Picked fresh for the demo so you can revoke at the end.
- [ ] **One or two `local_qemu` instances** ready to boot
      `powernode-hub`. Two are needed for the dual-NAT + endpoint
      failover scenarios; one is sufficient for the cert issue/renew/revoke
      bullets.
- [ ] **The pre-flight script run clean** — see
      [§ Pre-flight](#pre-flight).

## Pre-flight

Run the local-only check script that exercises the parts that don't need
real Cloudflare credentials. Catches regressions in seeds, cron
registration, Traefik dirs, factory wiring before you spend the 30 min:

```bash
cd server
bundle exec rails runner "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_acme_preflight.rb')"
```

Expected: every line ends with `OK`. Any `FAIL` aborts — fix before
proceeding to the live demo.

## Demo Scenario Map

Each acceptance bullet from the plan maps to one section below. Run in
order — later sections build on cert + credential records left in the DB
by earlier ones.

### 1. Issue a cert via Cloudflare DNS-01

**Acceptance**: provision `powernode-hub` on `local_qemu`, configure a
Cloudflare credential, request a cert for the test domain → cert lands
in Vault and Traefik serves it on :443 with a valid LE chain.

1. Boot `powernode-hub` on `local_qemu`:
   ```bash
   # MCP: system_provision_instance
   # Template: powernode-hub; provider: local_qemu
   ```
2. In the operator UI: `/app/system/acme` → "DNS Credentials" tab →
   New → name="Cloudflare smoke", provider=`cloudflare`, paste the API
   token. Click "Test Connectivity" — expect green check.
3. "Certificates" tab → "Request Certificate" → common_name=
   `acme-smoke.<your-zone>`, credential=the row from step 2.
4. Watch the status pill: `pending → validating → valid` (~60–180s for
   LE prod, ~30s for staging).
5. Verify on the box: `curl -v https://acme-smoke.<your-zone>/` — expect
   200 + a cert chain rooted at Let's Encrypt.

### 2. Manual cert renewal

**Acceptance**: issue cert renewal manually → new cert + private key in
Vault, Traefik reloads, no service interruption (<1s of failed
requests).

1. Start a curl loop in another terminal:
   ```bash
   while true; do curl -sS -o /dev/null -w "%{http_code} " https://acme-smoke.<your-zone>/; sleep 0.1; done
   ```
2. Click the "Renew" button on the cert from §1.
3. Watch the loop output — total failed requests should be <10
   (≤ 1 second of disruption).
4. Verify the cert's `expires_at` advanced by ~90 days.

### 3. Dual-NAT cert issuance

**Acceptance**: two `local_qemu` instances on the same NAT (no port
forwarding) both obtain LE certs via DNS-01.

1. Boot a second `powernode-hub` on the same NAT (no inbound 80/443
   forwarded).
2. Configure the same Cloudflare credential on the second hub.
3. Request a cert for a different subdomain (e.g.
   `hub2.<your-zone>`) — verify it transitions to `valid` without any
   port-forwarding gymnastics.

### 4. Endpoint advertisement (LAN preference)

**Acceptance**: configure two LAN-reachable peers with explicit LAN URLs
in `endpoints_jsonb`; one peer initiates federation handshake → client
probes LAN endpoint first → succeeds → all subsequent traffic flows via
LAN.

1. From hub1, propose federation to hub2:
   ```bash
   # MCP: system_sdwan_propose_federation_peer
   ```
   In the resulting peer row, manually edit `endpoints_jsonb` to put a
   LAN URL at priority 1 and the WAN URL at priority 3.
2. Accept the handshake on hub2.
3. Trigger a heartbeat: ssh hub1, `sudo systemctl restart powernode-worker@default` (or wait 60s).
4. `tcpdump` the LAN interface on hub2 — expect to see traffic from
   hub1's LAN IP, not the public NAT address.

### 5. Endpoint failover (sub-500ms)

**Acceptance**: simulate LAN endpoint going unreachable → client falls
through to SDWAN within 200ms × 1 attempt + 200ms × 1 attempt + WAN
success = within 500ms total.

1. With the LAN-preferring peer pair from §4 active, block the LAN
   route on hub1:
   ```bash
   sudo iptables -I OUTPUT -d <hub2-lan-ip> -j DROP
   ```
2. Trigger a probe (heartbeat) and time it:
   ```bash
   time rails runner "puts Federation::EndpointProber.probe!(peer: System::FederationPeer.find('<id>'))"
   ```
3. Expected: probe completes in <500ms, with `last_failure_at` set on
   the LAN endpoint and `last_verified_at` set on the next-priority
   endpoint that succeeded.
4. Restore: `sudo iptables -D OUTPUT -d <hub2-lan-ip> -j DROP`.

### 6. Cert revocation

**Acceptance**: revoke a cert via the AcmeCertificate model → next
request hits a deliberate failure (cert not honored); Traefik dynamic
config updated.

1. In the UI: cert detail → "Revoke" → confirm. (Or: `rails runner
   "Acme::CertificateManager.new.revoke!(certificate: System::AcmeCertificate.find('<id>'))"`)
2. Watch the curl loop from §2 (restart if you stopped it) — expect
   TLS handshake failures within a few seconds of revocation.
3. Verify Traefik dynamic config no longer references this cert:
   `grep <common_name> /etc/traefik/dynamic/certs.yml` → no match.

### 7. Spec coverage check

**Acceptance**: 8 request specs cover the auth + lifecycle paths.

The pre-flight script enumerates which spec files exist and maps each to
one of the 8 acceptance bullets. If pre-flight reports the count as ≥8
and the spec list matches the rubric, this bullet is closed.

To run them now:
```bash
cd server && bundle exec rspec \
  ../extensions/system/server/spec/requests/api/v1/system/acme_certificates_spec.rb \
  ../extensions/system/server/spec/requests/api/v1/system/acme_dns_credentials_spec.rb \
  ../extensions/system/server/spec/services/federation/endpoint_prober_spec.rb \
  --format progress
```

## Phase Report Template

After running all 6 scenarios, capture the transcript in a phase report
under `docs/federation/phase-reports/P2.5-acceptance-<date>.md`:

```markdown
## P2.5 Acceptance Report (<date>)

### Scenarios run
- [x] §1 Cert issue — duration: __, cert id: __
- [x] §2 Cert renewal — failed requests during reload: __
- [x] §3 Dual-NAT issue — second cert id: __
- [x] §4 Endpoint advertisement — tcpdump confirmed: y/n
- [x] §5 Endpoint failover — total time: __ms
- [x] §6 Cert revocation — Traefik config updated: y/n

### Deviations / findings
(blank if none)

### Acceptance decision
[ ] Full accept
[ ] Conditional accept (notes: __)
[ ] Reject (issues: __)
```

Once submitted + accepted, mark task #21 (P2.5.7) completed and the
gate is closed.
