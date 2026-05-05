# Example 01 — Single-node QEMU provisioning end-to-end

End-to-end walkthrough: from a clean machine to a running NodeInstance booted to `multi-user.target` via `LocalQemuProvider`. Uses the existing `smoke_test_provision.rb` seed.

**Goal:** confirm the full M3 + M4 boot pipeline works on your hardware before moving to cloud providers or production fleets.

**Audience:** developers + new operators validating the platform locally.

**Prerequisites:**
- Linux host (Ubuntu 24.04+ recommended) with virtualization extensions
- ≥8 GB RAM, ≥40 GB free disk
- Packages: `qemu-system-x86_64`, `libvirt-daemon-system`, `dracut`, `qemu-bridge-helper`, `golang-go ≥ 1.22`, `cosign`, `oras`
- The Powernode platform running locally (Rails server + Sidekiq worker, per the parent CLAUDE.md service management section)

## Step 1 — Build M3 artifacts (local initramfs)

```bash
cd extensions/system/initramfs
./build.sh
# → produces 6 artifact families × amd64+arm64 in ./build/
```

This takes 15–30 min on cold cache. The output is a directory tree with kernel + initramfs + raw + qcow2 + ISO + iPXE + OCI tarball, per arch.

## Step 2 — Run the smoke seed

```bash
cd server

POWERNODE_LIBVIRT_MODE=real \
POWERNODE_IMAGE_BASE=../extensions/system/initramfs/build \
bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_provision.rb')"
```

The seed:
1. Creates an Account + admin User
2. Seeds a NodePlatform pointing at the M3 artifact dir
3. Creates a Node (lifecycle_class=persistent) + a NodeTemplate
4. Provisions a NodeInstance via `LocalQemuProvider` in `real` mode
5. Watches the AASM Task transitions: `pending → provisioning → running`
6. Reports kernel boot pipeline events via `recent_events`

Expected console output:

```
[smoke_test_provision] Seeding account + user...
[smoke_test_provision] Seeded NodeArchitecture: amd64
[smoke_test_provision] Seeded NodePlatform: ubuntu-24.04-amd64
[smoke_test_provision] Created Node: smoke-node-1
[smoke_test_provision] Provisioning instance...
[smoke_test_provision] Task pending → provisioning (libvirt domain creating)
[smoke_test_provision] Task provisioning → running (kernel boot detected)
[smoke_test_provision] Watching agent enrollment...
[smoke_test_provision] First heartbeat received at 2026-05-04T09:23:14Z
[smoke_test_provision] Module pull + verify in progress...
[smoke_test_provision] Agent reported phase=ready; multi-user.target reached
[smoke_test_provision] ✅ Smoke complete in 4m 12s
```

Total runtime: ~15 min on cold boot (TCG without `/dev/kvm`); ~3–4 min with KVM.

## Step 3 — Verify

After the seed completes:

```bash
# Via MCP (if you have a JWT)
JWT=$(curl -s -X POST http://localhost:3000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@powernode.org","password":"<pw>"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['access_token'])")

curl -s http://localhost:3000/api/v1/system/instances \
  -H "Authorization: Bearer $JWT" | jq
# → { instances: [{ id, status: "running", last_heartbeat_at, ... }] }
```

Or via console:

```bash
virsh -c qemu:///session list
# → smoke-node-1   running
virsh -c qemu:///session console smoke-node-1
# → login prompt for the running VM
```

## Step 4 — Cleanup

```bash
# Terminate the instance
curl -X POST http://localhost:3000/api/v1/system/instances/<id>/terminate \
  -H "Authorization: Bearer $JWT"

# Or destroy the libvirt domain directly
virsh -c qemu:///session destroy smoke-node-1
virsh -c qemu:///session undefine smoke-node-1
```

## What to watch

- **`MissingNetbootImageError`**: `POWERNODE_IMAGE_BASE` doesn't point at a directory containing the M3 artifacts. Verify `ls $POWERNODE_IMAGE_BASE` shows `disk-image-arm64-uefi/`, `qcow2/`, etc.
- **TCG vs KVM**: `cat /proc/cpuinfo | grep -i vmx` confirms VT-x. If absent, the seed runs in TCG (slower).
- **`bridge-helper` permission denied**: `sudo setcap cap_net_admin+ep /usr/lib/qemu/qemu-bridge-helper` once.
- **Recorder mode** (no actual VM): set `POWERNODE_LIBVIRT_MODE=recorder` to skip libvirt and just record what the platform-side adapter *would* do — useful for unit tests.

## Related

- [`runbooks/node-provisioning.md`](../runbooks/node-provisioning.md) — full lifecycle reference
- [`SMOKE_TEST.md`](../SMOKE_TEST.md) — comprehensive smoke prerequisites + setup
- `db/seeds/smoke_test_provision.rb` — seed source
- Memory `project_local_qemu_provider` — adapter pattern (Libvirt/Recorder/Disabled)
