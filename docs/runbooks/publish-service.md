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
