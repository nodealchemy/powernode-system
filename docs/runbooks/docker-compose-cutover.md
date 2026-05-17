# Docker-Compose → Native Module Deployment — Cutover Runbook

**Scope**: operator-facing migration from the legacy
`docker-compose.prod.yml` stack to the platform's native module-based
deployment (Golden Eclipse P8 dogfooding). Single-host installations.

**Authoritative deprecation notice**: top of `./docker-compose.prod.yml`.

**Expected duration**: 60–90 minutes for a small instance with active
data; longer if you choose to do a parallel-run validation period.

**Cutover deadline (target)**: **2026-08-01**. After that date, the
docker-compose files become read-only and CI no longer publishes
the per-service Docker images.

---

## 1. What's being replaced

| Legacy (docker-compose.prod.yml) | New (P8 module-based) |
|---|---|
| `postgres` image container | `powernode-postgres` module — composefs blob + systemd unit |
| `redis` image container | `powernode-redis` module |
| `backend` Docker build | `powernode-hub-backend` module — Rails 8 API + ActionCable |
| `worker` Docker build | `powernode-hub-worker` module — Sidekiq |
| `frontend` Docker build | `powernode-hub-frontend` module — Vite static assets |
| `traefik` image container | `powernode-reverse-proxy` module — Traefik + ACME DNS-01 |
| Docker networks | SDWAN networks (Sdwan::Network rows) |
| `postgres_data` named volume | NFS / block ProviderVolume bound at deployment time |
| Image tags (mutable) | Cosign-signed OCI artifacts (immutable digests) |
| Docker restart loops | systemd `Restart=` directive per service |

All eight modules ship as composefs blobs from the M1 supply-chain
pipeline (`.gitea/workflows/build-platform-modules.yaml`) and are
attached to a `powernode-hub` NodeInstance via the on-node Go agent
(internal/lifecycle/AttachServices).

## 2. Prerequisites

- [ ] **Platform code at or after P8.5** (this commit).
- [ ] **Powernode platform module manifests on disk**:
      `ls extensions/system/modules/powernode-*/manifest.yaml` returns
      9 files.
- [ ] **Seeds run**: `bundle exec rails runner
      "load Rails.root.join('../extensions/system/server/db/seeds/powernode_platform_modules.rb')"`
      reports "9 platform module manifests" loaded.
- [ ] **Local QEMU provider configured** (for the cutover target host)
      OR a Linux host with composefs + fs-verity kernel support.
- [ ] **A reachable Postgres** containing the data you're migrating.
      Either the docker-compose Postgres still up, or an external dump
      file.
- [ ] **DNS + Cloudflare token** for the target hostname (if you want
      HTTPS via ACME DNS-01 — same setup as P2.5 acceptance gate).
- [ ] **A scheduled maintenance window** (10–30 min of database
      unavailability during cutover).

## 3. Cutover steps

### 3.1 Provision the target NodeInstance

```bash
# Either via MCP:
#   mcp: system_provision_instance with template=powernode-hub, provider=local_qemu
# Or via Rails console:
cd server && bundle exec rails runner '
account  = Account.first
template = System::NodeTemplate.find_by(account: account, name: "powernode-hub")
provider = System::Provider.find_by(account: account, provider_type: "local_qemu")
region   = provider.provider_regions.first
itype    = provider.provider_instance_types.find_by(instance_type_code: "qemu.medium")
node     = System::Node.create!(account: account, name: "prod-hub-1", node_template: template)
instance = System::NodeInstance.create!(account: account, node: node, name: "prod-hub-1",
  provider_instance_type: itype, provider_region: region, status: "pending")
System::InstanceControlService.execute(instance: instance, action: :start)
puts "Provisioned: #{instance.id}"
'
```

Expected: the on-node agent enrolls, fetches module manifests, writes
systemd unit files, starts services. ~5 minutes from start to a
running stack.

### 3.2 Database snapshot

While the legacy stack is still serving:

```bash
docker exec powernode-postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" \
  | gzip > /backup/cutover-$(date +%Y%m%d-%H%M%S).sql.gz
```

Keep this snapshot for 30 days regardless of cutover outcome.

### 3.3 Quiesce the legacy stack

```bash
# Stop sidekiq first so no new jobs queue
docker-compose -f docker-compose.prod.yml stop worker

# Drain in-flight requests — Traefik graceful drain
docker-compose -f docker-compose.prod.yml stop frontend backend

# Stop the auxiliary services
docker-compose -f docker-compose.prod.yml stop traefik
```

Database is still running — we'll dump from it after the worker has
flushed its queues (~30 seconds is typically sufficient).

### 3.4 Final dump + restore into the new Postgres

```bash
docker exec powernode-postgres pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" \
  > /tmp/cutover-final.dump

# Stop the legacy postgres
docker-compose -f docker-compose.prod.yml stop postgres

# Copy to the new hub host and restore
scp /tmp/cutover-final.dump prod-hub-1:/tmp/
ssh prod-hub-1 'sudo -u postgres pg_restore --clean --if-exists \
  -d powernode_production /tmp/cutover-final.dump'
```

### 3.5 Traffic shift

If the legacy stack was reachable via a DNS name (e.g.
`hub.example.com`), update the A/AAAA record(s) to point at the new
NodeInstance's public address. TTL on the old record should already
be ≤300s so the cutover completes within five minutes.

If the hostname is operator-internal (no public DNS), update
`/etc/hosts` on operator workstations or your internal DNS zone.

### 3.6 Validate the new stack

Run the P8.3 smoke test in real mode:

```bash
cd server && POWERNODE_LIBVIRT_MODE=real SMOKE_HUB_HOSTNAME=hub.example.com \
  bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_powernode_hub.rb')"
```

Expected: 11/11 pass, including HTTPS reachability + `/up` returning
200.

Additional smoke checks against the live HTTPS endpoint:
- [ ] Operator login via the dashboard
- [ ] A non-trivial mutation (e.g. create a test NodeInstance)
- [ ] At least one Sidekiq job processed end-to-end (check the
      operator's notifications feed — every dashboard action enqueues
      one)

## 4. Rollback

If validation fails at §3.6:

1. **Stop the new stack**:
   ```bash
   ssh prod-hub-1 'sudo systemctl stop powernode-019e29d3-*-rails.service \
                                          powernode-019e29d3-*-sidekiq.service \
                                          powernode-019e29d3-*-traefik.service'
   ```
2. **Restore the legacy stack** — DNS revert + `docker-compose
   -f docker-compose.prod.yml up -d`. The legacy Postgres still has
   the data as of §3.3 (cleanly stopped, not destroyed).
3. **Capture the failure** in
   `docs/cutover-incidents/<date>-prod-hub-1-rollback.md` for the
   next attempt.

Rollback target: ≤10 minutes from "this is broken" to "legacy stack
serving 200 responses again."

## 5. Decommission the legacy stack (after 7-day soak)

After a 7-day soak with the new stack running cleanly:

```bash
# Confirm no critical data was created on the legacy postgres after
# the cutover snapshot — if anything was, restore it manually.
diff <(docker exec powernode-postgres psql -tAc "SELECT MAX(updated_at) FROM users") \
     <(ssh prod-hub-1 'psql -tAc "SELECT MAX(updated_at) FROM users"')

# If clean: remove the legacy stack
docker-compose -f docker-compose.prod.yml down --volumes
docker image prune -a  # frees the powernode-* images
```

Snapshot retention: keep the §3.2 + §3.4 dumps for 90 days regardless.

## 6. Acceptance gate

Cutover is **accepted** when:
- [ ] §3.6 smoke is green
- [ ] §4 rollback wasn't needed
- [ ] 7-day soak shows no service incidents
- [ ] P8.4 cluster-member HA smoke runs clean against this host (if
      multi-host HA is in scope for this deployment)

Mark the cutover complete in `docs/cutover-log/<date>.md`. The next
release after the cutover removes `docker-compose.prod.yml` from the
build outputs entirely.

## Appendix — service-by-service unit-name mapping

The agent generates systemd unit names from `system_module_services`
rows as `powernode-<module-id>-<service-name>.service`. To find them
post-cutover:

```bash
ssh prod-hub-1 'systemctl list-units "powernode-*.service" --no-pager'
```

Typical output for a single-host hub:
```
powernode-019e2...-postgres.service   loaded active running
powernode-019e2...-redis.service      loaded active running
powernode-019e2...-traefik.service    loaded active running
powernode-019e2...-rails.service      loaded active running
powernode-019e2...-sidekiq.service    loaded active running
```

Journals: `journalctl -u powernode-019e2...-rails.service -f`.
