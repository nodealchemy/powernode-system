# Cloud‑VM `pivot_root` Deployment — Design

**Status:** design (2026-05-30) · **Goal owner:** maintainer

## Goal

A node should boot a **minimal guest**, then `pivot_root`/`switch_root` into a
**100% functional, modular `/sysroot`** composed from signed module blobs. The
module union *is* the operating system; the guest OS is a thin bootstrap,
unnecessary for full boot.

## Key finding — the model already exists (`direct_kernel`)

The `pivot_root` model is **implemented and proven** (bare‑metal/initramfs smoke,
2026‑05‑24). It is selected by `boot_mode: "direct_kernel"` on the Proxmox
provider. The managed‑child spawn this session used `boot_mode: "cloud_init"`
(the easier path), which is why ops2 ended up in the per‑unit `RootDirectory`
model rather than pivot_root. **Same agent binary, same erofs+overlay compose** —
only the boot entry differs.

| | `cloud_init` (what ops2 used) | `direct_kernel` (the goal) |
|---|---|---|
| Guest image | full Ubuntu 24.04 cloudimg | minimal kernel + initramfs (no rootfs disk) |
| Agent entry | `powernode-agent service` (post‑boot systemd unit) | `powernode-agent boot` in the **initramfs** |
| Identity | cloud‑init seed / `federation-payload.json` file | **fw‑cfg** (virtio) — mandatory, no file fallback |
| Root model | guest OS is `/`; module units chroot via `RootDirectory=/sysroot` | **`/sysroot` becomes `/`** via `systemctl switch-root` |
| Guest after boot | full Ubuntu still resident | irrelevant — modules are the OS |

### Where it lives (verified)
- Agent boot orchestrator: `agent/internal/boot/boot.go:111‑162` (identity → enroll → mount union → `systemctl switch-root /sysroot /sbin/init` at `:154‑161`, `systemctlSwitchRoot` at `:280‑283`).
- Compose (shared by both modes): `agent/internal/mount/overlay.go:76‑121` (overlay union), `agent/internal/mount/erofs.go:35‑78` (per‑module erofs loop‑mount).
- initramfs: `initramfs/modules.d/90powernode/` (dracut module: `init-powernode.sh`, `powernode-mount.service` runs `prepare-root` then `switch-root`; `powernode-federation-accept.service`).
- Provider dispatch: `proxmox_provider.rb:201‑225` (`boot_mode` → `create_vm_instance` vs `create_direct_kernel_vm_instance`); direct‑kernel impl `:860‑981` (`-kernel`/`-initrd`/`-append` via qemu `args`, fw‑cfg identity).
- Disk‑image CI already builds family #1 = **kernel + initramfs.cpio.zst** (`docs/DISK_IMAGE_CI.md`, `initramfs/README.md`), publishes as a signed OCI artifact, and points `NodePlatform.disk_image_oci_ref` at it.

## Target sequence (managed‑child hub via `direct_kernel`)

```
PVE VM boots -kernel/-initrd (no cloudimg, SeaBIOS, no grub)
  → systemd‑in‑initramfs (90powernode dracut module)
     → powernode-agent federation-accept   (fw-cfg: parent_url + acceptance_token)
     → powernode-agent boot:
          identity (fw-cfg) → enroll (mTLS) → PULL assigned modules (OCI) →
          compose /sysroot (erofs lowers + overlay upper) → bind /persist,/dev,/sys,/proc →
          systemctl switch-root /sysroot /sbin/init
  → systemd from the module union (PID 1) starts the hub services NATIVELY
     (postgres, redis, rails, sidekiq, traefik) — no per-unit RootDirectory needed
  → /health green
```

## Components, state, and gaps

1. **initramfs boot path is 9p/static, not OCI/dynamic — the PRIMARY work.**
   *Confirmed:* `runPrepareRoot` (`commands.go:173‑200`) mounts a **9p share**
   (`mount -t 9p … powernode_modules`, the libvirt `<filesystem>` block) and reads
   a **static `--modules` list** (default `["system-base"]`); `boot.go:221‑239`
   delegates to it. It does NOT call `node_api` for the assigned set nor pull
   erofs from the OCI registry. Only the `service`/reconcile path (`reconcile.go`:
   `FetchAssignedModules` → `Puller.Pull` (OCI) → `VerifyBlob` → `MountModule` →
   `Overlay.MountUnion`) does that. A Proxmox managed‑child has **no 9p share**.
   **Work:** extend the initramfs boot orchestrator to, pre‑pivot, run an
   OCI/dynamic compose — enroll (have) → fetch‑assigned (`node_api/modules`) →
   pull+verify each erofs from OCI → mount → compose `/sysroot` → `switch_root` —
   reusing the existing reconcile pull/compose code (service‑unit *start* stays
   post‑pivot, handled by systemd‑in‑the‑union). This is agent work, not just
   wiring. The kernel+initramfs artifact itself *exists* (disk‑image CI) and just
   needs a rebuild from current `agent/`.
2. **Staging on PVE** — **Gap:** `direct_kernel` reads `kernel_path`/`initrd_path`
   on the PVE host (default `/var/lib/vz/template/iso/powernode-{vmlinuz,initramfs.img}`).
   Need tooling to pull the published OCI kernel/initramfs onto rna/dna/fna/lna
   (or have the provider fetch+cache them), refreshed on each disk‑image publish.
3. **Spawn wiring** — provider supports `boot_mode`; **Gap:** `SpawnPlatformService`
   / `Federation::SpawnProvisioner` / the `powernode-hub` template must pass
   `boot_mode: "direct_kernel"` (+ kernel/initrd paths) in `spawn_target`.
4. **PVE `args` auth** — **Risk (known gate):** `direct_kernel` sets qemu `args`
   (`-kernel`/`-initrd`/fw‑cfg). PVE **token auth cannot set `args`**; only
   `root@pam`. The spawn runs via the API token → must either (a) use a
   root@pam‑scoped provider credential for direct‑kernel VMs, or (b) a
   create‑then‑`qm set --args` step over the admin‑sudoers SSH path. Resolve
   before P3.
5. **Stateful `/persist`** — postgres data + PKI must survive reboot. initramfs
   path bind‑mounts `/persist` into `/sysroot/var`. **Gap:** ensure the
   `direct_kernel` VM has a persistent disk for `/persist` (the impl supports
   `persist_storage_gb`).
6. **Module fixes (this session)** — offline gems (bundle cache + `--local` +
   runtime‑ruby bundler 2.7.1), `vendor/bundle` mask, JWT secret, pgvector,
   postgres `working_directory`, redis daemonize. **These apply unchanged** —
   the modules compose identically in both boot modes, so the cloud_init ops2
   run validated them for the direct_kernel path too.

## Phased plan

- **P1 — artifact:** build the kernel+initramfs from current `agent/`; confirm the
  initramfs `boot` path enrolls + pulls the *assigned* modules from OCI + composes
  + `switch_root`s. Stage kernel/initrd on the PVE hosts (or wire provider fetch).
- **P2 — wiring:** teach `SpawnPlatformService`/provisioner/`powernode-hub` template
  to spawn `boot_mode: "direct_kernel"` with the staged kernel/initrd; resolve the
  PVE `args`/root@pam auth path; attach a `/persist` disk.
- **P3 — prove:** spawn a hub child via `direct_kernel`; verify on the VM: fw‑cfg
  identity → enroll → 9 modules pulled+composed in initramfs → `switch_root` →
  systemd‑in‑union runs postgres/redis/rails → `/health` green; guest is *only*
  kernel+initramfs (no Ubuntu rootfs).
- **P4 — minimal guest:** confirm no cloudimg dependency; document the
  `direct_kernel` managed‑child runbook; make it the default `spawn_mode` boot for
  hubs.

## Open questions to settle in P1/P2
- ~~Does the in‑initramfs boot path fetch the assigned set + pull from OCI, or is
  it static?~~ **Answered:** static `--modules` + 9p share (libvirt). The boot path
  must be extended to OCI/dynamic (Component #1) — the primary implementation work.
- Cleanest place for the OCI compose in the initramfs: a new `boot`‑mode reconcile
  that reuses `reconcile.go`'s pull/compose, gated to *compose only* (no unit start)
  before `switch_root`; vs. a dedicated `prepare-root --source=oci` flag.
- Best mechanism to stage kernel/initrd on PVE (provider‑side fetch+cache of the
  signed OCI artifact vs. an ops pre‑stage step), refreshed on each disk‑image publish.
- root@pam vs token for qemu `args` on managed‑child spawns (the known PVE gate;
  security + automation tradeoff).
