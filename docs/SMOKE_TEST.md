# System Extension Smoke Test

End-to-end smoke test that exercises the complete dispatch chain: catalog → provider → libvirt → kernel boot. Two passes — `local` (RecorderRunner) and `real` (LibvirtRunner with actual QEMU).

## What it validates

| Stage | Pass 1 (`local`) | Pass 2 (`real`) |
|---|---|---|
| Catalog rows seeded | ✅ | ✅ |
| Provider adapter resolved | ✅ | ✅ |
| Bootstrap token issued (DB) | ✅ | ✅ |
| fw-cfg entries assembled | ✅ | ✅ |
| Domain XML built | ✅ | ✅ |
| `virsh define` | recorded | ✅ actual |
| `virsh start` | recorded | ✅ actual |
| QEMU process spawns | — | ✅ |
| Kernel boots | — | ✅ |
| initramfs unpacks + runs | — | ✅ |
| systemd reaches multi-user.target | — | ✅ |
| Agent enrollment | — | ❌ (gated, see below) |
| Module pull | — | ❌ (gated) |
| Heartbeat | — | ❌ (gated) |

## Prerequisites

| Requirement | How |
|---|---|
| QEMU + libvirt | `sudo apt install qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst` |
| dracut | `sudo apt install dracut dracut-network` |
| Boot tools | `sudo apt install mmdebstrap fsverity xorriso skopeo erofs-utils` |
| Sigstore tools | `~/.local/bin/{cosign,syft,grype,oras}` (download from upstream releases) |
| Go toolchain | `sudo apt install golang-go` (≥1.22) |
| dracut module symlink | `sudo ln -sfn $PWD/extensions/system/initramfs/modules.d/90powernode /usr/lib/dracut/modules.d/90powernode` |
| `qemu-bridge-helper` capability (only `POWERNODE_NETWORK_MODE=bridge`) | Auto-installed by `scripts/systemd/powernode-installer.sh` via `powernode-qemu-bridge-cap.service`. Manual: `sudo setcap cap_net_admin+ep /usr/lib/qemu/qemu-bridge-helper`. Without this, `virsh start` fails with `failed to create tun device: Operation not permitted` |

`/dev/kvm` is **optional** — without it the domain XML uses `<domain type='qemu'>` (TCG software emulation, slower but functional).

## Setup steps

### 1. Build the agent

```bash
cd extensions/system/agent
go mod tidy
make build-amd64
mkdir -p ../initramfs/scripts
cp dist/powernode-agent-linux-amd64 ../initramfs/scripts/powernode-agent-amd64
```

### 2. Build the kernel + initramfs

```bash
cd extensions/system/initramfs
bash build.sh --arch amd64 --variants kernel-initrd
```

Outputs land in `build/amd64/kernel-initrd/{kernel,initramfs.cpio.zst,SHA256SUMS}`.

### 3. Seed the smoke-test catalog

```bash
cd server
bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_catalog.rb')"
```

Creates: NodeArchitecture (amd64), NodePlatform (ubuntu-24.04-lts), Provider (smoke-local-qemu, type=local_qemu), ProviderConnection, ProviderRegion (local), ProviderInstanceType (smoke.small/.medium), 3 NodeModules (system-base, apache, nginx), 3 NodeTemplates (smoke-base, smoke-web-apache, smoke-web-nginx).

### 4. Provision (Pass 1 — RecorderRunner)

```bash
cd server
POWERNODE_LIBVIRT_MODE=local bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_provision.rb')"
```

Validates the dispatch chain logically — no VM is started, but the bootstrap token is issued, the domain XML is built, and the adapter returns success.

### 5. Provision (Pass 2 — real libvirt)

```bash
cd server
POWERNODE_LIBVIRT_MODE=real \
POWERNODE_LIBVIRT_URI=qemu:///session \
POWERNODE_IMAGE_BASE=$(realpath ../extensions/system/initramfs/build) \
POWERNODE_FWCFG_DIR=/tmp/powernode-fwcfg \
POWERNODE_SERIAL_LOG_DIR=/tmp/smoke-serial \
SMOKE_NODE_NAME=smoke-real-1 \
SMOKE_INSTANCE_NAME=smoke-real-1-vm \
bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_provision.rb')"
```

Watches the kernel boot via `/tmp/smoke-serial/domain-serial.log`:

```bash
tail -f /tmp/smoke-serial/domain-serial.log
```

You'll see the kernel cmdline with `lockdown=integrity ima_appraise=enforce powernode.boot=1`, dracut unpacking the initramfs, systemd-networkd configuring the virtio NIC, and the system reaching multi-user.target.

### 6. Cleanup

```bash
virsh -c qemu:///session list --all                           # show domains
virsh -c qemu:///session destroy   powernode-smoke-<XXXXXXXX> # stop
virsh -c qemu:///session undefine  powernode-smoke-<XXXXXXXX> --nvram
```

## Environment variables

| Var | Default | Purpose |
|---|---|---|
| `POWERNODE_LIBVIRT_MODE` | `local` (dev) / `real` (prod) | `real` = LibvirtRunner, `local` = RecorderRunner, `disabled` = error fast |
| `POWERNODE_LIBVIRT_URI` | `qemu:///system` | `qemu:///session` skips libvirt group / sudo dance |
| `POWERNODE_LIBVIRT_NETWORK` | `default` | name of the libvirt network (system-mode only) |
| `POWERNODE_NETWORK_MODE` | `user` (session) / `network` (system) | `user` (slirp NAT), `network` (libvirt virbr0+dnsmasq), or `bridge` (true LAN bridge) |
| `POWERNODE_BRIDGE_NAME` | `br0` | name of the host bridge interface when mode=bridge |
| `POWERNODE_IMAGE_BASE` | `/var/lib/powernode/images` | dir containing `<arch>/kernel-initrd/{kernel,initramfs.cpio.zst}` |
| `POWERNODE_FWCFG_DIR` | `/var/run/powernode-fwcfg` | where CloudSeed writes virtio-fw-cfg payloads |
| `POWERNODE_SERIAL_LOG_DIR` | (unset) | when set, redirects domain serial console to a per-domain log file |
| `POWERNODE_DISK_DIR` | `/var/lib/libvirt/images` | dir containing pre-staged `<domain>.qcow2` (skipped when not present) |
| `POWERNODE_PLATFORM_URL` | `http://localhost:3000` | URL the agent dials for `/node_api/enroll` |
| `POWERNODE_CA_PEM` | fixture PEM | inline CA chain (until `InternalCaService.public_chain` lands via Vault PKI) |

## Smoke-test seed scripts

| Path | Purpose |
|---|---|
| `extensions/system/server/db/seeds/smoke_test_catalog.rb` | Seeds the catalog. Idempotent (find_or_create_by). |
| `extensions/system/server/db/seeds/smoke_test_provision.rb` | Drives `LocalQemuProvider.create_instance`. Reports each step. |

## Example modules

Three module-repo scaffolds under `extensions/system/templates/example-modules/`:

| Module | Purpose | Provides |
|---|---|---|
| `system-base` | Ubuntu 24.04 minbase + systemd-networkd + sshd | `base.os`, `net.systemd-networkd`, `sshd` |
| `apache` | Apache 2.4 mpm_event with secure-headers vhost | `http.server`, `http.port:80` |
| `nginx` | nginx 1.24 with secure-headers vhost + `/healthz` | `http.server`, `http.port:80` |

Each ships a `manifest.yaml`, a real `rootfs/` configuration, and a README. They are inline examples; production modules belong in their own Gitea repos following the same shape (see `extensions/system/templates/module-repo/` for the canonical authoring template).

## What's gated (not validated by the smoke test)

These are M0.N / M1 / M2 production deliverables:

| Capability | Gated on |
|---|---|
| Agent successfully enrolls | Vault PKI mounted (`pki_int`) + `InternalCaService` returns real CA chain + Traefik configured for mTLS termination + platform endpoint reachable from VM (NAT'd network) |
| Module artifacts pulled and verified | Gitea registry online + module CI dispatch + cosign keyless signing via Sigstore Fulcio + composefs-tools (or fallback to erofs+dm-verity) |
| Heartbeat updates `last_heartbeat_at` | Agent enrolled (above) + heartbeat endpoint reachable |
| Module-drift sensor produces signals | Modules actually mounted; drift between `assigned_module_versions` and `running_module_digests` |
| Real-hardware verification | M3.5 — at least one bare-metal x86 + arm64 boot via iPXE chainload |

## Findings (2026-05-02 first run)

- **No /dev/kvm on dev box (initial)** — host was itself a KVM guest with nested-virt disabled at L0. QEMU ran in TCG mode (~30s of CPU to reach multi-user.target). DomainXmlBuilder auto-detects this and switches `<domain type='kvm'>` → `<domain type='qemu'>` and `cpu mode='host-passthrough'` → `'host-model'`. **Update 2026-05-02:** L0 nested-virt enabled; cold-boot the L1 host to expose `/dev/kvm`. After cold boot, the auto-detect path picks KVM with no code change. Verify with the post-VMX sanity check below.
- **dracut needs custom-modules path workaround** — modules in `extensions/system/initramfs/modules.d/90powernode/` are not seen by dracut by default. Workaround: symlink into `/usr/lib/dracut/modules.d/`. M3 follow-up: have `build.sh` create the symlink in a temp dracut prefix dir.
- **dracut hook (`pre-mount/90`) doesn't run when there's no `root=`** — without a rootfs to switch_root onto, dracut treats the initramfs as the OS, runs systemd inside it, and skips the pre-mount hook entirely. The agent never starts. **M3 follow-up:** ship `powernode-agent-boot.service` as a systemd unit baked into initramfs (multi-user.target dependent), not just as a dracut hook.
- **Provider model PROVIDER_TYPES needed `local_qemu`** — Registry knew about `local_qemu`, model validation didn't. Fixed in this commit.
- **CloudSeed didn't stage fw-cfg files** — DomainXmlBuilder referenced `/var/run/powernode-fwcfg/` paths but no service wrote them. Now `CloudSeed.build` writes each entry; both layers reference `CloudSeed::FWCFG_DIR` shared constant.
- **DomainXmlBuilder hardcoded `<source network='default'/>`** — fails on `qemu:///session` (no libvirt-managed networks). Now auto-detects session URI and uses `<interface type='user'/>` (slirp NAT mode).
- **DomainXmlBuilder hardcoded a qcow2 disk** — failed when disk path didn't exist. Now skipped when `POWERNODE_DISK_DIR/<domain>.qcow2` is absent.
- **Ubuntu 24.04 dropped network-legacy** — `dracut --modules powernode` failed because powernode depends on `network` which depends on `network-legacy` which needs `dhclient` (not installed). Fixed by switching the powernode module to depend on `systemd-networkd` instead.
- **`/boot/vmlinuz-*` is mode 0600** — Ubuntu KASLR hardening since 2018. `build.sh` now uses sudo to read; destination is owned by the build user so subsequent `sha256sum` runs don't need elevation.
- **`build.sh` picked the first /lib/modules entry** — could be an orphaned dir without a corresponding /boot/vmlinuz. Now picks `KERNEL_VERSION` env override → running kernel → newest with both modules + image.
- **`qemu-bridge-helper` ships without `CAP_NET_ADMIN`** — `qemu:///session` shells out to `/usr/lib/qemu/qemu-bridge-helper` to attach a tap to a host bridge. On Debian/Ubuntu the package leaves it unprivileged (no SUID, no caps), so `virsh start` fails with `failed to create tun device: Operation not permitted`. Capability survives reboots but is reset by `qemu-system-*` upgrades. Fix: `powernode-qemu-bridge-cap.service` re-applies `setcap cap_net_admin+ep` on every boot (idempotent), wired into `powernode-installer.sh`.
- **Bridge-mode VM has no in-guest DHCP yet** — initramfs ships `systemd-networkd` but no `.network` file matching `enp1s0` (only container/vm-vt/6rd/wifi defaults). Networkd is fail-closed without a matching unit, so the guest reaches `multi-user.target` with the NIC link-up and no IP. Intentional: the agent is meant to read fw-cfg first and apply per-instance network policy. Gated on the M3 `dracut hook → systemd-unit` refactor that lands `powernode-agent-boot.service` in the initramfs.

## Cookbook recipes

### Watch the boot live

```bash
mkdir -p /tmp/smoke-serial
POWERNODE_SERIAL_LOG_DIR=/tmp/smoke-serial   # ... run smoke_test_provision.rb
tail -f /tmp/smoke-serial/domain-serial.log
```

### Inspect fw-cfg from inside the VM (when agent is running)

```sh
cat /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/instance_uuid
cat /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/bootstrap_token
```

### Re-define after fixing code (no full rerun needed)

```bash
virsh -c qemu:///session destroy <domain> && virsh -c qemu:///session undefine <domain> --nvram
# … re-run smoke_test_provision.rb
```

### Force VM to use TCG even if /dev/kvm exists (for cross-arch testing)

```ruby
# extensions/system/server/app/services/system/providers/local_qemu/domain_xml_builder.rb
domain_type = ENV["POWERNODE_FORCE_TCG"] == "1" ? "qemu" : (File.exist?("/dev/kvm") ? "kvm" : "qemu")
```

(not yet wired — TODO if cross-arch testing becomes needed)

### Bridged networking with upstream LAN DHCP

Three modes are supported via `POWERNODE_NETWORK_MODE`:

| Mode | VM IP source | Host setup | When to use |
|---|---|---|---|
| `user` | qemu slirp (10.0.2.15) | none | quick smoke; VM-to-host via 10.0.2.2 NAT |
| `network` | libvirt dnsmasq (192.168.122.x) | virbr0 active (already is on this host) | DHCP w/ stable IPs but still NAT'd |
| `bridge` | upstream router DHCP (LAN address) | a Linux bridge with the host's NIC enslaved | VM is a peer on the LAN |

**Host bridge setup (NetworkManager — current renderer on this host):**

```bash
# 1. Find the existing wired connection name
nmcli -g NAME,DEVICE con show --active | grep enp6s18

# 2. Create the bridge
sudo nmcli con add type bridge ifname br0 con-name br0
sudo nmcli con modify br0 ipv4.method auto ipv6.method auto

# 3. Move the wired NIC into the bridge (replace <wired-con-name> with output from step 1)
sudo nmcli con add type bridge-slave ifname enp6s18 master br0 con-name br0-slave-enp6s18
sudo nmcli con down "<wired-con-name>"      # WARNING: this drops your SSH session if you're remote
sudo nmcli con up br0
sudo nmcli con modify "<wired-con-name>" autoconnect no    # prevent reverting on reboot

# 4. Verify the bridge has the host's IP and the upstream gateway
ip -br addr show br0
ip route show default
```

**Allow `qemu:///session` VMs to attach** (qemu-bridge-helper is setuid root and consults this allowlist):

```bash
sudo mkdir -p /etc/qemu
echo 'allow br0' | sudo tee -a /etc/qemu/bridge.conf
sudo chmod 0640 /etc/qemu/bridge.conf
sudo chgrp kvm /etc/qemu/bridge.conf      # so the helper can read it
```

**Run the smoke provision in bridge mode:**

```bash
cd server
POWERNODE_LIBVIRT_MODE=real \
POWERNODE_LIBVIRT_URI=qemu:///session \
POWERNODE_NETWORK_MODE=bridge \
POWERNODE_BRIDGE_NAME=br0 \
POWERNODE_IMAGE_BASE=$(realpath ../extensions/system/initramfs/build) \
POWERNODE_FWCFG_DIR=/tmp/powernode-fwcfg \
POWERNODE_SERIAL_LOG_DIR=/tmp/smoke-serial \
SMOKE_NODE_NAME=smoke-bridge-1 \
SMOKE_INSTANCE_NAME=smoke-bridge-1-vm \
bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_provision.rb')"

# Verify the VM got a real LAN lease (run from the host, after the agent runs DHCP)
sudo arp -an | grep 52:54:00     # qemu virtio MACs prefix
ip neigh | grep 52:54:00
```

**Caveats specific to nested-virt hosts:**

This dev box is itself a KVM L1 guest (`systemd-detect-virt=kvm`). For a true LAN bridge to work on top of a virtio L1 vNIC:

- L0 hypervisor must allow MAC spoofing on the L1 vNIC. Otherwise, frames originating from the VM's MAC (which differs from the L1's) are silently dropped.
- In Proxmox: VM → Network → check "MAC filtering: off" or set "trunk" mode.
- In libvirt L0: remove any `<filterref filter='clean-traffic'/>` from the L1 domain XML.
- In KubeVirt: add `spec.template.spec.networks[].pod.macAllowance: All` (or use `multus` with a bridge that doesn't filter).
- In VMware ESXi: enable "Promiscuous mode: Accept" + "MAC address changes: Accept" + "Forged transmits: Accept" on the L1 portgroup.

If the bridge is up but VM packets still don't get DHCP responses, check `tcpdump -i br0 port 67 or port 68` from the host — if you see DHCPDISCOVER going out but no DHCPOFFER coming back, that's the L0 dropping foreign-MAC frames.

### Post-VMX (KVM-enabled) sanity check

After a cold boot with VMX enabled at L0:

```bash
# 1. Verify the kernel sees CPU virt extensions
grep -m1 -oE 'vmx|svm' /proc/cpuinfo

# 2. Verify the KVM modules loaded
lsmod | grep -E 'kvm_intel|kvm_amd|^kvm '

# 3. Verify the device file exists
ls -la /dev/kvm

# 4. Check libvirt picks it up
sudo virsh -c qemu:///system capabilities | grep -A 1 '<domain'

# 5. Re-run the smoke provision (same env vars as before — no code changes)
cd server
POWERNODE_LIBVIRT_MODE=real \
POWERNODE_LIBVIRT_URI=qemu:///session \
POWERNODE_IMAGE_BASE=$(realpath ../extensions/system/initramfs/build) \
POWERNODE_FWCFG_DIR=/tmp/powernode-fwcfg \
POWERNODE_SERIAL_LOG_DIR=/tmp/smoke-serial \
SMOKE_NODE_NAME=smoke-kvm-1 \
SMOKE_INSTANCE_NAME=smoke-kvm-1-vm \
bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_provision.rb')"

# 6. Verify the auto-detected domain type
virsh -c qemu:///session dumpxml smoke-kvm-1-vm | grep -E "domain type|cpu mode"
# Expected: <domain type='kvm' …> and <cpu mode='host-passthrough' …>

# 7. Watch boot — should reach multi-user.target in ~3-5s instead of ~30s
tail -f /tmp/smoke-serial/domain-serial.log
```

If `/dev/kvm` is still missing after a warm `reboot`, do a full `poweroff` + power-on. Some hypervisors only re-evaluate guest CPU feature flags on cold boot.
