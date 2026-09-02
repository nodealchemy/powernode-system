# Publish a Service Locally at `/svc/<slug>` — Operator Runbook

> Status: active

End-to-end operator procedure for publishing an internal/overlay backend service
to the site's **own authenticated users** at a friendly `/svc/<slug>` path on the
platform's existing host(s) — no new public port, no new certificate. The reverse
proxy (Traefik) authenticates each request via a **ForwardAuth** middleware before
proxying to the backend.

This is the **local sibling** of [`expose-service.md`](./expose-service.md) (public
internet) and the local plane of the broader **Service Exposure Subsystem**
(`Sdwan::Service`). For exposing the *same* service across federated links to other
sites, see [`federation-setup.md`](./federation-setup.md).

**Audience:** SREs and platform operators publishing internal dashboards/APIs
(Grafana, admin tools, overlay services) to their own users behind login.

**Companion docs:**
- [`expose-service.md`](./expose-service.md) — the public-internet sibling (VIP + DNAT + ACME).
- [`sdwan-network-setup.md`](./sdwan-network-setup.md) — create the overlay network + VIP the backend lives on.
- [`../../../docs/operations/reverse-proxy.md`](../../../docs/operations/reverse-proxy.md) — bundled Traefik architecture (G1).

## What the local-exposure flow does

A backend service is modeled as a first-class **`Sdwan::Service`** (identity + slug +
overlay backend [a VIP or static host] + port). Its **local-exposure facet** turns it
into a `/svc/<slug>` router:

1. **Resolve-or-create the service** — `system_create_service`, or inline in the expose call.
2. **Enable the local facet** — `system_expose_service_local` (approval-gated) sets
   `local_enabled` + the auth mode + optional scoped permission/group + strip-prefix +
   which host certificate's CN to mount under.
3. **Regenerate the proxy** — `Sdwan::ServiceExposureWriter` writes
   `local-services-<account>.yaml` into the Traefik dynamic dir; Traefik **file-watches
   and hot-reloads** (no restart).

The resulting router (`localsvc-<id>`):

```
rule:        (Host(`<cert CN>`) || …trusted hosts…) && PathPrefix(`/svc/<slug>`)
entryPoints: [websecure]            tls.options: mtls-optional@file
middlewares: forwardauth → stripprefix → headers
service:     loadBalancer → <protocol>://<vip-or-host>:<port>   (passHostHeader)
```

Rule-length auto-priority makes `PathPrefix(/svc/<slug>)` win over the frontend
catch-all on the same host — no manual `priority:` needed.

### Load balancing across replicas (APO-3c)

A service's `backend_vip`/`backend_host` + `backend_port` columns describe **one**
backend. Scaling a project out does not, on its own, spread traffic: the exposed
service keeps pointing at that one address. The fan-out is an explicit
**backend set** — `Sdwan::ServiceBackend` rows hanging off the service:

| Column | Meaning |
|---|---|
| `backend_vip_id` / `backend_host` + `backend_port` | this member's address, same shape as the service's own columns (a set may mix ports) |
| `weight` | 1..1000, weighted round robin. Uniform weights *are* round robin |
| `status` | `active` \| `draining` — a draining member keeps its row and its history but leaves the emitted server list |

What the writer emits changes only once a service has **two or more active
members**:

```
service: loadBalancer
  servers:     one entry per active member, in (created_at, id) order
  weight:      per server, only when the members' weights DIFFER
  healthCheck: { path, interval, timeout }   (http/https facet only)
```

- **A service with no backend set renders exactly as before, byte for byte** —
  no weights, no health check, one server. Nothing backfills a row for the
  legacy columns, so no existing service changes shape until someone adds one.
- **Draining every member is NOT how you take a service out of rotation.** The
  active set is then empty and the writer falls back to the service's *legacy*
  `backend_host`/`backend_vip` columns — which, after a replace-instance cycle,
  may name a host that no longer answers. To stop routing, clear
  `local_enabled`/`public_enabled`; the writer skips a disabled service.
- **The public TCP (Path B) facet fans out too**, but round robin only: Traefik's
  TCP servers load balancer has no per-server weight (WRR there is a
  service-level construct) and no health check on the vendored build.

> **No API or MCP verb writes the backend set or a service's `metadata` yet.**
> This increment (APO-3c) ships the load-balancing *capability*; the producer —
> replace-instance and scale-out maintaining the set — is APO-4. Until then a
> backend set and the per-service overrides below are **rails-console only**.
> The account and SiteSetting tiers *are* reachable today.

Health-check defaults resolve through `Sdwan::ServiceLoadBalancing`, in order:
the service's own `metadata["load_balancer"][<key>]`, then the account's
`settings["system.sdwan.service_load_balancing.<key>"]`, then the SiteSetting of
that key, then the constant.

| Key | Default |
|---|---|
| `health_check_enabled` | `false` (opt-in) |
| `health_check_path` | `/` |
| `health_check_interval` | `10s` |
| `health_check_timeout` | `3s` |

**Health checking is opt-in, on purpose.** Traefik drops a check-failing server
from the pool and answers `503` once none are left, so a health check pointed at
the wrong path does not degrade a scaled service — it takes the whole service
dark, which is worse than the single unchecked backend it replaced. A
health-check path is also not a deployment-wide fact: Grafana answers
`/api/health`, Rails `/up`, a bare exporter `/`. So turn it on where you know the
path, e.g. per service:

```ruby
svc.update!(metadata: svc.metadata.merge(
  "load_balancer" => { "health_check_enabled" => true, "health_check_path" => "/-/ready" }
))
```

or deployment-wide once every scaled backend agrees on one:

```ruby
SiteSetting.set("system.sdwan.service_load_balancing.health_check_enabled", true)
SiteSetting.set("system.sdwan.service_load_balancing.health_check_path", "/healthz")
```

A lower tier always beats a higher one, and `false` counts as a value — a
per-service `health_check_enabled: false` switches the check off under a
deployment-wide `true` without giving up the fan-out.

### Auth modes (the ForwardAuth gate)

`GET /api/v1/system/ingress/forward_auth?service=<id>` is called by Traefik with the
caller's original `Authorization`/cookies **before** proxying. It returns:

| Mode | Who gets in | Identity headers forwarded to backend |
|------|-------------|----------------------------------------|
| `public` | everyone — the forwardAuth middleware is omitted entirely | (none) |
| `authenticated` | any valid platform user in the owning account | `X-Powernode-User/Account/Groups` |
| `scoped` | a user holding `local_required_permission` **or** in `local_required_group` | `X-Powernode-User/Account/Groups` |

`trustForwardHeader: false` + the backend ignoring client-supplied `X-Powernode-*`
neutralizes header spoofing — the backend trusts only the proxy-injected copies.

## Steps (MCP / Concierge)

> Permissions: read = `system.ingress.read`; all mutations = `system.ingress.manage`.
> The admin role is granted both (plus `system.acme.manage`).

**Option A — one shot (create + expose):**

```
system_expose_service_local
  slug: grafana            name: "Grafana"
  protocol: https          backend_vip_id: <vip>   # or backend_host: 10.20.0.5
  backend_port: 3000       auth_mode: authenticated
```

This is **approval-gated** — via the Concierge it raises an inline Approve/Reject
card (skill **Expose Service Locally**) before it runs.

**Option B — create first, expose later:**

```
system_create_service   slug: grafana name: "Grafana" backend_host: 10.20.0.5 backend_port: 3000
system_list_services                                   # confirm it exists (local_enabled: false)
system_expose_service_local  service_id: <id>  auth_mode: scoped  required_permission: services.grafana.view
```

**Day-2:**

- `system_update_service` — change name/protocol/status/backend (identity + plumbing
  only; it will **not** flip `local_enabled` — exposure semantics are owned by the
  approval-gated expose action). Regenerates the proxy if the service is exposed.
- `system_unexpose_service_local` — fail-safe **off** (no approval); keeps the record.
- `system_delete_service` — removes the service (and its route if it was exposed).

## Verify

```bash
# Unauthenticated → 401 (ForwardAuth denies)
curl -sk -o /dev/null -w '%{http_code}\n' https://<host>/svc/<slug>/

# With a valid platform JWT → 200 (auth passes, prefix stripped, proxied to backend)
curl -sk -H "Authorization: Bearer <token>" \
  -o /dev/null -w '%{http_code}\n' https://<host>/svc/<slug>/

# Inspect the generated router
cat "$POWERNODE_TRAEFIK_DYNAMIC_DIR/local-services-<account-id>.yaml"
```

Force a regen without an executor: `./scripts/manage-proxy-hosts.sh sync-traefik`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `/svc/<slug>` returns the SPA (200 HTML) instead of the backend | No `localsvc-*` router — service not `local_enabled`, or regen didn't run. Re-run expose or `sync-traefik`. |
| Route doesn't appear for ~1–2s after a change | Traefik file-watch reload lag — normal; poll again. |
| Service silently skipped (no router) | No host resolvable — the service has no `local_certificate` **and** the account has no valid cert. A hostless `PathPrefix` router would hijack `/svc/<slug>` on every host, so the writer skips it with a logged warning. Assign a `certificate_id` or issue an account cert. |
| `scoped` service rejects everyone (403) | The user lacks `local_required_permission` and isn't in `local_required_group`. |
| Wrong dynamic dir | The writer resolves `POWERNODE_TRAEFIK_DYNAMIC_DIR` → `/etc/traefik/dynamic` → `Rails.root/tmp/traefik/<env>/dynamic`. It must match the **running** proxy's dir. |

## Relationship to the public + federated planes

| Plane | Reach | Auth | Built from |
|-------|-------|------|-----------|
| **Local** (this runbook) | site's own users, `/svc/<slug>` | ForwardAuth (platform login) | `Sdwan::Service` local facet → `Sdwan::ServiceExposureWriter` |
| **Public** ([`expose-service.md`](./expose-service.md)) | open internet, `https://<fqdn>` | none (or backend's own) | VIP + hub DNAT + ACME + `Acme::TraefikConfigWriter` |
| **Federated** ([`federation-setup.md`](./federation-setup.md)) | other sites/entities | mTLS peer + per-peer `FederationGrant` | `Federation::ServiceOffering` → subscriber `Federation::ServiceRouteWriter` |

All three are facets of one service identity and share one Traefik dynamic dir with
non-colliding key namespaces (`localsvc-*`, `<slug>-*`, `sub-*`).
