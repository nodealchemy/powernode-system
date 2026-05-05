# Example 03 — Multi-tenant container farm with SDWAN isolation

End-to-end walkthrough: each tenant gets a managed Docker host on its own SDWAN network. Tenants can't see or reach each other's daemons. Companion runnable seed: `db/seeds/example_multi_tenant.rb` (Phase 3).

**Goal:** demonstrate multi-tenant container hosting where the trust boundary is SDWAN network membership, not just TLS daemon credentials.

**Audience:** SaaS operators, platform admins building multi-tenant infrastructure.

**Prerequisites:**
- Examples 01 + 02 working
- ≥3 NodeInstances available (one per tenant + an operator workstation peer)

## Concept

```
             ┌───────────────────────────┐
             │ Operator (your laptop)    │
             │ peer on tenant-a + tenant-b networks │
             └──────────┬──────┬─────────┘
                        │      │
        SDWAN: tenant-a │      │ SDWAN: tenant-b
        ┌───────────────┴┐    ┌┴────────────────┐
        │ Tenant A's     │    │ Tenant B's      │
        │ docker-engine  │    │ docker-engine   │
        │ (managed host) │    │ (managed host)  │
        └────────────────┘    └─────────────────┘
            ↑                       ↑
      cannot reach              cannot reach
      tenant-b's daemon         tenant-a's daemon
```

The two tenants are on **separate SDWAN networks**. Even though both have publicly-routable management addresses (the daemon `/128`), the routing is contained within each SDWAN network — no cross-network reachability.

## Step 1 — Provision the underlying instances

Per [`runbooks/node-provisioning.md`](../runbooks/node-provisioning.md):

```javascript
platform.system_create_node({ hostname: "tenant-a-host", node_template_id: "<docker-template>", ... })
platform.system_provision_instance({ node_id: tenant_a_node_id, ... })

platform.system_create_node({ hostname: "tenant-b-host", node_template_id: "<docker-template>", ... })
platform.system_provision_instance({ node_id: tenant_b_node_id, ... })
```

Wait ~90s for both to bootstrap.

## Step 2 — Create per-tenant SDWAN networks

```javascript
platform.system_sdwan_create_network({
  name: "tenant-a",
  description: "Tenant A's docker farm",
  routing_mode: "static"
})
// → { network: { id: "net-tenant-a", prefix: "fd00:abcd:1::/64", ... } }

platform.system_sdwan_create_network({
  name: "tenant-b",
  description: "Tenant B's docker farm",
  routing_mode: "static"
})
// → { network: { id: "net-tenant-b", prefix: "fd00:abcd:2::/64", ... } }
```

Different `/64` prefixes guarantee non-overlapping address spaces.

## Step 3 — Attach each tenant to its own network

```javascript
platform.system_sdwan_attach_peer({
  network_id: "net-tenant-a",
  node_instance_id: "<tenant-a-instance>"
})

platform.system_sdwan_attach_peer({
  network_id: "net-tenant-b",
  node_instance_id: "<tenant-b-instance>"
})
```

Each tenant peer gets a `/128` from its respective network's `/64`. Cross-network reachability is implicitly blocked — there's no route between the two `/64`s.

## Step 4 — Provision Docker on each tenant

```javascript
platform.system_provision_docker_runtime({
  node_instance_id: "<tenant-a-instance>"
})
// → { host: { id: "host-a", api_endpoint: "tcp://[fd00:abcd:1::42]:2376", ... } }

platform.system_provision_docker_runtime({
  node_instance_id: "<tenant-b-instance>"
})
// → { host: { id: "host-b", api_endpoint: "tcp://[fd00:abcd:2::42]:2376", ... } }
```

Each tenant's daemon listens on its own `/128`, with TLS provisioned via `InternalCaService`. The TLS certs are tenant-specific — Tenant A's client cert won't validate against Tenant B's server cert.

## Step 5 — Operator: peer on both networks

For the operator to manage both tenants, attach an operator workstation peer to both:

```javascript
platform.system_sdwan_create_access_grant({
  network_id: "net-tenant-a",
  device_name_hint: "ops-laptop"
})
// → { bootstrap_url, expires_at }

platform.system_sdwan_create_access_grant({
  network_id: "net-tenant-b",
  device_name_hint: "ops-laptop"
})
// → { bootstrap_url, expires_at }
```

User opens both bootstrap URLs (or scans QRs) → WireGuard config has two `[Peer]` sections, one per network.

## Step 6 — Verify isolation

From your operator workstation, both daemons are reachable:

```javascript
platform.docker_list_containers({ host_id: "host-a" })   // works
platform.docker_list_containers({ host_id: "host-b" })   // works
```

But tenant A's host cannot reach tenant B's:

```bash
# SSH (or `system_execute_task`) to tenant-a-host:
nc -zv fd00:abcd:2::42 2376
# → connection refused / network unreachable
```

The platform's MCP layer also enforces tenant scoping — actions on `host-a` require permissions scoped to tenant A's account.

## Step 7 — Add firewall rules within a tenant

For tenant A to enforce intra-tenant isolation (e.g., dev vs prod docker hosts on the same network):

```javascript
platform.system_sdwan_create_firewall_rule({
  network_id: "net-tenant-a",
  direction: "ingress",
  action: "drop",
  selector: { kind: "tag", tag: "tenant-a-prod" },
  protocol: "tcp",
  port_range: "2376"
})

platform.system_sdwan_create_firewall_rule({
  network_id: "net-tenant-a",
  direction: "ingress",
  action: "accept",
  selector: { kind: "tag", tag: "tenant-a-prod-admin" },
  protocol: "tcp",
  port_range: "2376"
})
```

Now only peers tagged `tenant-a-prod-admin` can reach prod docker daemons; default-deny otherwise.

## Step 8 — Cleanup

```javascript
platform.system_decommission_docker_runtime({ host_id: "host-a" })
platform.system_decommission_docker_runtime({ host_id: "host-b" })
platform.system_terminate_instance({ id: "<tenant-a-instance>" })
platform.system_terminate_instance({ id: "<tenant-b-instance>" })
platform.system_sdwan_delete_network({ id: "net-tenant-a" })
platform.system_sdwan_delete_network({ id: "net-tenant-b" })
```

## What to watch

- **Trust boundary is the SDWAN account ownership** — sharing an account across tenants defeats the isolation. For true multi-tenant SaaS, give each tenant their own Powernode account with cross-account federation peers (slice 11) for limited cross-tenant traffic.
- **Cross-host Docker overlay (Swarm) is NOT supported** — for true cross-host orchestration use K3s instead (see Example 02).
- **Use SDWAN firewall rules for intra-tenant isolation** — within one network, all peers can reach each other's daemon `/128` unless rules prevent it.

## Related

- [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — use case 6 (multi-tenant container farm)
- [`runbooks/sdwan-network-setup.md`](../runbooks/sdwan-network-setup.md) — SDWAN concepts
- [`CONTAINER_RUNTIMES.md`](../CONTAINER_RUNTIMES.md) — Phase 1 Docker lifecycle
