# Ingress & TLS Guide

> Status: active

Operator guide for the System extension's **ingress / TLS** feature — how the
platform fronts an internal service with a stable public endpoint, terminates
TLS at the reverse proxy (Traefik v3), and keeps the certificate live through
the ACME lifecycle.

This is the operator-facing companion to the lower-level cert runbook
[`runbooks/acme-issuance.md`](./runbooks/acme-issuance.md) (day-2 cert
lifecycle: issuance, renewal, revocation, DR) and to
[`CONCIERGE_PROVISIONING_GUIDE.md`](./CONCIERGE_PROVISIONING_GUIDE.md) (the
Concierge mission + inline-approval flow that the Expose-Service wizard rides
on). The reverse-proxy / mTLS architecture is documented in
[`ARCHITECTURE.md`](./ARCHITECTURE.md) §"API surfaces" (Node mTLS).

**Audience:** SREs and platform operators publishing internal services to the
public internet with TLS.

---

## 1. What the feature does

Exposing a backend service to the internet normally means wiring four
primitives by hand. The ingress feature chains them into **one
approval-gated operation**:

1. **SDWAN Virtual IP (VIP)** — a stable overlay address that fronts the
   backend instance/peer.
2. **Hub port mapping** — a DNAT rule on a publicly-reachable hub peer that
   forwards `:443` (https) / `:80` (http) to the VIP plus the backend port.
3. **ACME certificate** — a Let's Encrypt TLS cert for the service hostname,
   issued via a DNS-01 challenge.
4. **Reverse-proxy regen** — folds the new cert into the Traefik dynamic
   config so the platform serves it. Traefik file-watches the config dir and
   reloads with no dropped connections.

The whole chain lives in
[`System::Ai::Skills::ExposeServicePubliclyExecutor`](../server/app/services/system/ai/skills/expose_service_publicly_executor.rb).
IDs thread between steps: the VIP id becomes the port mapping's
`target_virtual_ip_id`; the issued `certificate_id` drives the reverse-proxy
regen.

```
VIP ──► hub port-map (DNAT :443 → VIP:backend_port) ──► ACME cert (DNS-01) ──► Traefik regen
```

### http vs https semantics

- **https** — the ACME cert and the reverse-proxy regen are **hard
  requirements**. If either fails, the whole expose fails (`failure(...)`) —
  there is no silent partial success. A broken cert would mean a broken
  public endpoint, so the operation refuses to "succeed" without TLS.
- **http** — the cert step is **skipped** entirely (no TLS to provision);
  only the VIP and the port mapping (listening on `:80`) are created.

The first two steps (VIP + port mapping) are always hard requirements —
a failure there aborts before any cert work begins, so you never end up with
a half-issued cert pointing at nothing.

### Idempotent re-runs

- **VIP** is reused when a VIP named `expose-<hostname>` already exists in the
  network — re-runs don't pile up VIPs.
- **Cert** is reused when a `valid`, unexpired cert for the hostname already
  exists — no needless ACME round-trips.

---

## 2. The Ingress page (UI)

The System extension ships an Ingress hub at **`/app/system/ingress`**
([`IngressPage.tsx`](../frontend/src/pages/app/system/IngressPage.tsx)) with
two path-based tabs, each gated by its own permission:

| Tab | Path | Permission | Purpose |
|-----|------|------------|---------|
| **Routes** | `/app/system/ingress/routes` | `system.ingress.read` | Read-only monitor of derived Traefik routers |
| **Expose Service** | `/app/system/ingress/expose` | `system.ingress.manage` | Approval-gated wizard to publish a service |

If you hold neither permission the page tells you which to request. If you hold
only `system.ingress.read`, you see Routes but not the wizard.

### Routes monitor

The Routes tab
([`IngressRoutesPanel.tsx`](../frontend/src/features/system/components/ingress/IngressRoutesPanel.tsx))
is a **read-only projection** — there is no create/update/delete here by
design. Each row is derived from one issued `System::AcmeCertificate` and is
fetched from `GET /api/v1/system/ingress_routes`
([`ingressApi.ts`](../frontend/src/features/system/services/api/ingressApi.ts)).
A row shows:

- The derived **host matcher** (`Host(`metrics.example.com`)`, OR-joined when
  extra hosts are configured).
- The cert **lifecycle status** pill: `pending`, `issuing`, `valid`,
  `renewing`, or `revoked` (a route is "live in Traefik" only when `valid`).
- The **issuer**, **expiry date**, and a days-until-expiry counter (turns
  warning-colored under 30 days).
- A router count. Expanding a row reveals the per-cert Traefik routers
  (router name → path prefix → backend service → entrypoint) plus convenience
  public-URL links.

The same routers shown here are the ones
[`TraefikConfigWriter.routers_for(cert)`](../server/app/services/acme/traefik_config_writer.rb)
emits into the live dynamic config — the monitor and the write path share one
source of truth, so they never drift. Each cert produces nine routers (the
operator API, agent/cable, the internal/worker/federation/node mTLS APIs, and
a frontend catchall), all on the single `websecure` (`:443`) entrypoint.

### Expose-Service wizard

The Expose Service tab
([`ExposeServicePanel.tsx`](../frontend/src/features/system/components/ingress/ExposeServicePanel.tsx))
collects the structured fields below and, on submit, does **not** call any
ingress executor or REST endpoint directly. Instead it composes a
natural-language brief and sends it through the **System Concierge**, which
classifies the intent and produces an approval-gated mission with an inline
Approve/Reject card (see [§5](#5-the-concierge-driven-expose-mission)).

| Field | Notes |
|-------|-------|
| Public hostname | e.g. `metrics.example.com` — the certificate CN |
| Protocol | `http` or `https` |
| Backend port | the port the backend service listens on (DNAT target) |
| SDWAN network | populated from the account's networks |
| SDWAN hub peer | populated after a network is chosen; pick a publicly-reachable hub |
| VIP CIDR | operator-supplied host CIDR (see [§3](#3-the-expose-lifecycle-inputs)) |
| TLS issuer | issuer slug (the wizard shows a `letsencrypt` placeholder — supply `letsencrypt-staging` for first runs) |
| DNS credential | a stored `System::AcmeDnsCredential` (for DNS-01) |

The right-hand "Mission approval" pane is the Concierge conversation — the
plan and its Approve/Reject card render there after you submit.

---

## 3. The expose lifecycle (inputs)

`expose_service_publicly` takes these inputs (validated by the executor up
front so it fails fast and clearly, before creating any resources):

| Input | Required | Notes |
|-------|----------|-------|
| `service_hostname` | yes | Public FQDN, e.g. `metrics.example.com` (the cert CN) |
| `service_protocol` | yes | `http` or `https` |
| `sdwan_network_id` | yes | network the VIP + port mapping live in |
| `sdwan_hub_peer_id` | yes | publicly-reachable hub peer that terminates the public port |
| `vip_cidr` | yes | operator-supplied **host** CIDR — a `/128` within the network's `/64` (IPv6) or a `/32` (IPv4). There is no allocator; you choose the address. |
| `backend_port` | yes | the DNAT `target_port` |
| `target_peer_id` *or* `target_instance_id` | exactly one | the backend to front (XOR — providing both or neither is rejected) |
| `tls_issuer` | no (default `letsencrypt-prod`) | `letsencrypt-staging` or `letsencrypt-prod` |
| `challenge_type` | no (default `dns-01`) | `dns-01` is the supported path |
| `dns_credential_id` | conditional | **required** for `https` + `dns-01` |

Notes on the targets:

- A VIP with no holder fronts nothing, so the executor refuses to create a
  holderless VIP. If you pass `target_instance_id`, the executor resolves it
  to the instance's `Sdwan::Peer` **in that network** — if the instance has no
  peer there, the operation fails with a clear message ("attach the instance
  to the network first or pass `target_peer_id`").
- For `https` + `dns-01`, a missing `dns_credential_id` is rejected **before**
  the VIP and port mapping are created.

> **Always run with `letsencrypt-staging` first.** Production Let's Encrypt
> enforces rate limits (50 certs / week / registered domain). Validate the
> whole chain end-to-end against staging, then re-run with
> `letsencrypt-prod`. The served leaf will say `(STAGING)` in its issuer when
> you're on staging — see [§8](#8-verifying-the-result).

---

## 4. Certificate issuance, renewal, revocation, and the DNS credential model

The cert step delegates to
[`AcmeCertificateProvisionExecutor`](../server/app/services/system/ai/skills/acme_certificate_provision_executor.rb),
which creates a `System::AcmeCertificate` in `pending` and drives it through
`Acme::CertificateManager.issue!`. Cert material (PEM / key / chain / ACME
account key) is written to **Vault**; only the Vault path labels are returned.

- **Issuers** (`System::AcmeCertificate::ISSUERS`): `letsencrypt-prod`,
  `letsencrypt-staging`, `internal-ca`.
- **Challenge types** (`CHALLENGE_TYPES`): `dns-01`, `http-01`,
  `tls-alpn-01`. The bundled ACME tooling drives `dns-01` (the default and
  the path the wizard uses).
- **Renewal** is automatic: a Sidekiq cron (every 6h) re-issues certs within
  30 days of expiry through the same flow. The Traefik reload on renewal is
  non-disruptive (sub-second).
- **Revocation** is irreversible and removes the cert from Traefik
  immediately; to re-enable, issue a new cert. Don't revoke for routine
  rotation — just renew.

For the full day-2 cert procedures (single + multi-SAN issuance, manual
renew, revoke, DR), see [`runbooks/acme-issuance.md`](./runbooks/acme-issuance.md).

### DNS credential model

A DNS-01 challenge needs the platform to write a `_acme-challenge` TXT record
via the DNS provider's API. That is configured once as a
`System::AcmeDnsCredential`
([model](../server/app/models/system/acme_dns_credential.rb)):

- The credential row carries `name`, `provider`, validation `status`, and the
  Vault path. **The provider API token itself lives in Vault** (credential
  type `acme_dns`) — it is never stored in the DB row.
- Configure it under the ACME surface (`/app/system/acme` → DNS Credentials),
  then "Test Connectivity" before first use. Stale tokens (>24h since
  validation) are re-tested by the renewal job before they're used to solve a
  challenge.
- In the Expose-Service wizard the credential appears in the **DNS
  credential** dropdown by `name (provider)`.

> **Supported DNS providers (all wired end-to-end).** Both the model's
> `SUPPORTED_PROVIDERS` and the on-node ACME issuer implement seven DNS-01
> providers: **cloudflare, route53, gcloud, digitalocean, hetzner, porkbun,
> ovh**. A credential for any of the seven validates at save time and issues
> at challenge time — the on-node Go issuer wires the matching lego adapter
> in `buildDNSProvider`
> ([`agent/internal/acme/issuer.go`](../agent/internal/acme/issuer.go)).

---

## 5. The Concierge-driven expose mission

The Expose-Service wizard never calls the ingress executor directly. On
submit it sends a natural-language brief into the operator's **System
Concierge** conversation, embedding the structured fields. The Concierge
classifies the intent and composes an **approval-gated mission** — the same
mission + inline-approval mechanism documented in
[`CONCIERGE_PROVISIONING_GUIDE.md`](./CONCIERGE_PROVISIONING_GUIDE.md).

Because the underlying skill declares `requires_approval: true`, **nothing is
exposed until you approve**:

1. Fill out the wizard and submit. The mission appears in the right-hand
   pane.
2. The Concierge posts an **Approve / Reject card** inline in the
   conversation. The plan (VIP → port-map → cert → proxy) is shown but not
   executed.
3. Click **Approve** to run the chain, or **Reject** to abort. Approval is
   the only path to execution.

You can also kick the same flow off conversationally — just ask the
Concierge to "make `metrics.example.com` reachable from the internet at port
`8080`" and answer its follow-up questions. The wizard simply pre-fills a
clean brief so the deterministic classifier and the LLM both have every field.

---

## 6. MCP actions

For scripting, the ingress surface is exposed via
[`Ai::Tools::SystemIngressTool`](../server/app/services/ai/tools/system_ingress_tool.rb).
The tool floor permission is `system.ingress.read`; write actions require the
permission shown below.

| Action | Permission | What it does |
|--------|------------|--------------|
| `system_expose_service_publicly` | `system.ingress.manage` | Full chain: VIP → port-map → cert → reverse-proxy regen |
| `system_acme_provision_certificate` | `system.acme.manage` | Issue a single ACME cert for a hostname (no VIP/port-map) |
| `system_reverse_proxy_compose` | `system.ingress.manage` | Regenerate Traefik dynamic config for an already-`valid` cert |

`system_expose_service_publicly` takes the same inputs as [§3](#3-the-expose-lifecycle-inputs).
`system_acme_provision_certificate` takes `common_name`, `issuer`,
`challenge_type`, optional `sans`, `dns_credential_id` (required for
`dns-01`), and `acme_email`. `system_reverse_proxy_compose` takes a single
`certificate_id` whose status must be `valid`.

> **No MCP action to validate a DNS credential (yet).** Credential validation
> runs through the Rails-only `Acme::DnsCredentialValidator` service (and the
> "Test Connectivity" button in the ACME UI). There is **no**
> `system_acme_validate_dns_credential` MCP action today, so a script can't
> pre-flight a stored credential before calling `system_acme_provision_certificate`
> — exposing such an action is a proposed enhancement. For now, validate via
> the UI before scripting issuance.

> When run through the Concierge as a mission, the operation is
> approval-gated. Calling the MCP action directly still flows through the
> skill executor's `requires_approval: true` gate.

---

## 7. Staging vs. prod issuers

| Issuer slug | Use it for | Notes |
|-------------|-----------|-------|
| `letsencrypt-staging` | **first runs, validation, drills** | Untrusted root (browsers warn); no production rate limits. The served leaf's issuer string contains `(STAGING)`. |
| `letsencrypt-prod` | real public endpoints | Browser-trusted; subject to LE rate limits (50 certs / week / registered domain). Default if `tls_issuer` is omitted. |
| `internal-ca` | platform-internal hostnames | Verified against the platform's internal CA; not publicly trusted. |

Recommended sequence: run the full expose once with `letsencrypt-staging`,
verify the cert is served and routing works ([§8](#8-verifying-the-result)),
then re-run with `letsencrypt-prod`. Re-runs reuse the VIP and port mapping;
the cert is re-issued because the staging leaf isn't a valid prod cert.

---

## 8. Verifying the result

After an expose completes, verify two things independently.

**The served certificate** — confirm Traefik is serving the LE leaf (not its
fallback self-signed cert):

```bash
echo | openssl s_client -connect <traefik-host>:443 -servername metrics.example.com \
  | openssl x509 -noout -subject -issuer -dates
```

Expect the Let's Encrypt leaf in `subject` / `issuer` (with `(STAGING)` in
the issuer when you're on staging). If you instead see `TRAEFIK DEFAULT
CERT`, Traefik isn't serving your cert — the cert isn't `valid` yet, or the
reverse-proxy regen didn't run.

**Routing** — confirm the route reaches your backend without depending on
public DNS yet, by pinning the hostname to the Traefik IP locally:

```bash
curl -k --resolve metrics.example.com:443:<traefik-ip> \
  https://metrics.example.com/<path>
```

(`--resolve` and `-k` keep this a pure routing check; it does not prove
public reachability.)

### What public reachability actually requires

A local `--resolve` check passing does **not** mean the service is reachable
from the public internet. For that you also need:

- An **SDWAN hub peer with `publicly_reachable=true`** holding a routable
  public IP — this is the DNAT hub that terminates `:443`.
- A public **A / AAAA record** for the hostname pointing at that hub's public
  IP, so real clients resolve the name to the hub.

Note: the **DNS-01 cert validation itself does not need an A/AAAA record** —
lego proves control of the domain by writing a TXT record via the provider
API, which is independent of where the hostname's A record points. So a cert
can issue cleanly while the service is still not publicly reachable (no A
record / no public hub).

---

## 9. Troubleshooting

### Split-brain DNS — `could not find zone for domain ... SERVFAIL`

The most common DNS-01 failure on internal hosts. If the host's system
resolver can't resolve the public zone (a split-horizon resolver that returns
`SERVFAIL` on the zone's SOA, or an internal authoritative NS that can't see
the public record), lego's zone-detection fails with an error like:

```
could not find zone for domain "metrics.example.com": ... SERVFAIL
```

**Fix:** point the ACME tooling at a public recursive resolver via an
environment variable on the unit that runs issuance (systemd unit / Rails
env):

```
POWERNODE_ACME_DNS_RESOLVERS="1.1.1.1:53,1.0.0.1:53"
```

This is read by
[`agent/internal/acme/issuer.go`](../agent/internal/acme/issuer.go)
(`buildChallengeOptions`) and makes lego use the listed public resolvers when
polling propagation, sidestepping the internal NS entirely.

**Last resort:** `POWERNODE_ACME_DISABLE_PROPAGATION_CHECK=true` skips lego's
"all authoritative NS must agree" pre-check. Use sparingly — Let's Encrypt's
own external validation still has to succeed, so this only helps when the
*local* propagation check is the false blocker.

### DNS provider credential fails at issuance

All seven providers (cloudflare, route53, gcloud, digitalocean, hetzner,
porkbun, ovh) are wired end-to-end (see
[§4](#4-certificate-issuance-renewal-revocation-and-the-dns-credential-model)),
so a save-time validation pass no longer implies a different provider would
silently fail. If a credential that validated at save time now errors at
issuance, the usual cause is a **scope-narrowed or expired token** — re-test
the credential's connectivity (stale tokens >24h are re-tested by the renewal
job, but a manual re-test surfaces the failure immediately).

### 403 on the served hostname — host allowlists

In production the served hostnames must be allowlisted, or requests are
rejected with **403** before they reach a route. Add the public hostname to
both:

- the frontend dev server's `allowedHosts` (Vite), and
- Rails `config.hosts` (HostAuthorization).

If a brand-new hostname returns 403 while the cert is `valid` and Traefik is
serving it, an allowlist is almost always the cause.

### Cert stuck at `pending` / `issuing`

The cert step is a hard requirement for `https`, so a stuck cert fails the
whole expose. Common causes:

- **DNS provider token scope** insufficient — re-test the credential's
  connectivity.
- **Split-brain DNS** — see above; set `POWERNODE_ACME_DNS_RESOLVERS`.
- **LE rate limit** on prod — switch to `letsencrypt-staging` or wait for the
  rate window.

For deeper cert diagnostics (TXT propagation, multi-SAN mixed zones, Traefik
reload failures), see [`runbooks/acme-issuance.md`](./runbooks/acme-issuance.md)
§"Common failure modes".

### Served cert is `TRAEFIK DEFAULT CERT`

Traefik is falling back to its self-signed cert. Either the cert isn't
`valid` yet, or the reverse-proxy regen didn't run. Re-run
`system_reverse_proxy_compose` for the `certificate_id` (it re-emits the
account's dynamic YAML from its valid certs; Traefik file-watch reloads
automatically).

### Expose fails: "target_instance_id ... has no SDWAN peer in network"

The instance you're fronting isn't attached to the chosen SDWAN network.
Attach it first, or pass `target_peer_id` directly.

### Reachable on `--resolve` but not from the internet

The route is correct but public reachability is missing — verify the hub peer
is `publicly_reachable` with a routable public IP, and that a public A/AAAA
record points at it. See
[§8](#what-public-reachability-actually-requires).

---

## Cross-references

- [`runbooks/acme-issuance.md`](./runbooks/acme-issuance.md) — day-2 cert
  lifecycle (issuance, renewal, revocation, DR)
- [`CONCIERGE_PROVISIONING_GUIDE.md`](./CONCIERGE_PROVISIONING_GUIDE.md) —
  the Concierge mission + inline approval card the wizard rides on
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — reverse proxy, single `websecure`
  entrypoint, optional-mTLS termination
- [`MCP_API_REFERENCE.md`](./MCP_API_REFERENCE.md) — the `system_*` MCP action
  surface
- [`ExposeServicePubliclyExecutor`](../server/app/services/system/ai/skills/expose_service_publicly_executor.rb)
  — the end-to-end orchestrator
- [`TraefikConfigWriter`](../server/app/services/acme/traefik_config_writer.rb)
  — derives the routers shown in the Routes monitor and the live config

_Last verified: 2026-06-03_
