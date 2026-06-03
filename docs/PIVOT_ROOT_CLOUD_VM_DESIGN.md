# Cloud‑VM `pivot_root` Deployment — Design

> Status: design — not yet shipped. The kernel+initramfs artifact is mechanically
> proven (boot → systemd-in-initramfs → agent invoked; see memory
> `powernode.pivot_root_smoke_proven_2026_05_24`); the OCI/dynamic boot compose +
> `switch_root` path (P1 below) is the primary unimplemented work.

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

## P1 implementation design (from code read)

- **`boot.Orchestrator.mountUnion` is a stub** (`internal/boot/boot.go:224‑241`,
  returns nil) — the real mount is the separate `prepare-root` subcommand (9p).
  The Orchestrator carries only `Resolver`/`EnrollClient`/`MountRunner`/`Layout`,
  **not** the OCI deps. `runtime.RunOnce` (`reconcile.go:170‑402`) has the OCI
  compose: `FetchAssignedModules` → manifest `LoadOrFetch` → `attachModule`
  (Puller.Pull → Verifier → `MountModule`) → `etcidentity`/`etcsudoers` →
  `AttachServices` (renders units with **`RootDirectory=/sysroot`** + starts them)
  → `Overlay.MountUnion`.

- **Minimal pivot only needs system-base.** The initramfs is minimal (agent +
  busybox + systemd + CA); it pulls + composes **system-base** from OCI and
  pivots. The hub modules (postgres/redis/rails/…) can be pulled + composed
  **post‑pivot** by the existing `service`/reconcile loop running in the union.

- **Decision — post‑pivot service model:**
  - **(A) Chroot / reuse (pragmatic):** initramfs composes system-base from OCI →
    `switch_root` → the agent (shipped in system-base) runs the *existing* reconcile,
    which pulls the hub modules + renders units with `RootDirectory=/sysroot` (a
    *re-composed* `/sysroot` nested inside the now-union root). **Smallest change**
    — boot only learns to pull+compose the base from OCI; everything else is
    today's code. Slightly redundant (double compose), services chroot rather than
    run native, but functionally the guest is minimal and the OS is the module union.
  - **(B) Native (pure modular OS):** compose the *full* assigned set pre‑pivot,
    render units **without** `RootDirectory` + **enable** them, `switch_root`, and
    systemd-in-the-union starts services natively at `/`. Closest to the stated
    goal, but a real lifecycle refactor (native vs chroot units, enable-vs-start,
    boot composes all modules, post-pivot reconcile must be native-aware).

  **DECISION (2026‑05‑30): Option B — native modular OS.** Services run natively in
  the union at `/` post‑pivot (no `RootDirectory`). The sysroot *is* the OS.

### B implementation blueprint
1. **lifecycle (`internal/lifecycle/service.go`):** add a *root mode* to
   `RenderUnit`/`AttachServices`: **native** = no `RootDirectory`, add
   `[Install] WantedBy=multi-user.target` + `systemctl enable` (no immediate
   `start` — systemd-in-union starts it on boot); vs the current **chroot** =
   `RootDirectory=/sysroot` + `start`. Gate via a flag threaded from the
   Reconciler/Orchestrator. Keep chroot mode intact (cloud_init still uses it).
2. **boot orchestrator (`internal/boot/boot.go`):** implement `mountUnion` to run a
   *compose-for-pivot*: `FetchAssignedModules` → pull+verify+mount **all** erofs
   (reuse `reconcile.attachModule`'s pull/mount) → `etcidentity`/`etcsudoers` into
   the union → render+**enable** native units → `Overlay.MountUnion` → return; then
   `Boot` calls `switch_root`. Add OCI deps to `Orchestrator` (construct a
   `runtime.Reconciler` in native + compose‑only mode, or factor the compose core
   into a shared func both call).
3. **post‑pivot reconcile (`internal/runtime`):** run in **native** mode — the
   union is `/`; new modules attach natively (no re‑compose‑and‑chroot); units
   rendered native+enabled.
4. **artifact + wiring:** rebuild kernel+initramfs from current `agent/`; stage on
   PVE; spawn with `boot_mode=direct_kernel` + kernel/initrd paths; resolve the PVE
   `args`/root@pam gate; attach a `/persist` disk.
5. **prove:** spawn a hub via `direct_kernel` → fw‑cfg identity → enroll → all
   modules composed in the initramfs → native units enabled → `switch_root` →
   systemd‑in‑union starts postgres/redis/rails **at `/`** → `/health` green; the
   guest is *only* kernel+initramfs (no Ubuntu rootfs).

### Prerequisite — base-OS layer in the template (CONFIRMED MISSING)
`powernode-agent status` on the cloud_init ops2 shows **ROOTFS=no for all 9 hub
modules** — none provides a base root OS. cloud_init gets its base from the
**guest Ubuntu** (units chroot into `/sysroot` via `RootDirectory`), so the hub
template never needed one. The pivot model has **no guest base**: after
`switch_root` the union *is* `/`, so it must contain `/sbin/init` (systemd),
coreutils, glibc, the FHS. The base layer is resolved by the **`base.os`
capability**: `base-os-ubuntu-noble` provides `base.os` (Ubuntu 24.04 userland,
systemd PID 1) and requires `powernode-system-base` (ships `/sbin/powernode-agent`),
both at lowest priority. **Fix: the direct_kernel hub template must `require:
base.os`** so the resolver folds these in as the bottom layers. This is a template
change, not agent code — `ComposeForPivot` already composes the assigned set
(including the resolved base) in priority order. Belongs in P2 wiring.

**Verified on ops (2026‑05‑30):** the `powernode-hub` template lists 9 modules,
none with a `base.os` capability and no base.os requirement column.
`base-os-ubuntu-noble` (v6, ~70 MB, digest ✓) is built + ingested — the Ubuntu
userland (systemd/FHS) to pivot into. **But `powernode-system-base` is v3 / 4 KB
— HOLLOW**: the CI cross-compiles `/sbin/powernode-agent` into it and that didn't
land (same build-gap class as the hollow frontend). Since `base-os-ubuntu-noble`
*inherits* the agent from `powernode-system-base`, the composed union would have
systemd+FHS but **no `/sbin/powernode-agent`** → hub services would still run
post-pivot, but the post-pivot agent (heartbeat, cert rotation, module updates)
couldn't start. So P2 base-OS work is **two** items: (a) template `require:
base.os`; (b) fix the hollow `powernode-system-base` agent cross-compile (or have
`base-os-ubuntu-noble` ship the agent directly). Also untangle the
`powernode-system-base` vs `powernode-system-base-ubuntu-noble` (v3, ~70 MB)
name duplication so the resolver picks the right base.

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

---

_Last verified: 2026-06-03_
