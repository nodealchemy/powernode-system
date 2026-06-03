# Baked-Union Disk Image — Universal Modular-OS Composition

**Status:** Design — proposed 2026-05-30. Extends
[`PIVOT_ROOT_CLOUD_VM_DESIGN.md`](./PIVOT_ROOT_CLOUD_VM_DESIGN.md). Depends on its
prerequisites landing first (a real `powernode-system-base`; pivot P2 proven once).

## Problem

Composition is **not universal** today. `ProxmoxProvider#create_instance` defaults
`boot_mode` to `cloud_init`, and that is the only path ever exercised in production:

| Path | Default? | Availability | How modules compose |
|---|---|---|---|
| `cloud_init` | **yes** | every provider | stock guest OS = `/`; union mounted at `/sysroot`; services **chrooted** via systemd `RootDirectory=/sysroot` |
| `direct_kernel` | no (opt-in) | **hypervisor only** (PVE/local_qemu — needs `-kernel/-initrd`) | kernel+initramfs; union becomes `/` via `switch_root` (pivot) |

The pivot/modular-OS model (Option B — "the union *is* the OS") is therefore the
**exception**, and it is structurally unreachable on image-based clouds: AWS/GCP/Azure
boot a **disk**, not a `-kernel -initrd` pair, so they can never use `direct_kernel`.

## Goal

**One composition method for every node instance, on every provider:** a published,
cosign-signed **disk image with the resolved module union baked in**, that boots a
modular `/` whether it lands on a cloud (AMI/image), a hypervisor (qcow2), bare metal
(USB/SD/ISO/PXE), or a bootc host. The guest OS becomes minimal/unnecessary — the
union is the OS — exactly as on the `direct_kernel` pivot path, but delivered as a
bootable disk instead of via the hypervisor.

## What already exists (reuse, do not rebuild)

| Capability | Where | Note |
|---|---|---|
| Disk-image build CI → **6 artifact families** | `.gitea/workflows/build-disk-image.yaml`, `initramfs/build.sh` | kernel+initramfs, **raw `.img`**, ISO, iPXE, **qcow2**, **bootc-OCI** — per arch |
| Disk-image publish/ingest + cosign verify | `System::DiskImagePublication*`, `disk_image_oci_ingest_service.rb`, `DiskImageWebhook` | OCI digest → `NodePlatform.disk_image_oci_ref` + retention |
| Union assembly + pivot | agent `internal/boot` + `runtime.ComposeForPivot` + `lifecycle.AttachServicesNative` (P1) | mount erofs layers → overlay → identity/native units → `switch_root` |
| Per-module erofs + fs-verity + cosign | `build-platform-modules.yaml`, module registry | the layers the union is built from |
| `machine_image` plumbing on `ProviderRegion` | providers | where a published image ref is wired per region |

The `direct_kernel` artifacts (family 1) and the `.img`/qcow2 families are the **same
bytes** (kernel + initramfs + erofs), packaged for different boot mechanisms. So the
P1/P2 pivot work is *exactly* what runs inside a baked image — baking is a **delivery
superset of `direct_kernel`**, not a competing path.

## Design

### Image layout (layered — recommended over flatten)

```
┌── disk image (.img / qcow2 / AMI snapshot / bootc OCI) ──────────────┐
│  ESP / boot   : GRUB + vmlinuz + initramfs.cpio.zst                  │
│  layers       : the template's resolved erofs blobs (read-only)      │
│                 base-os-ubuntu-noble, powernode-system-base,         │
│                 postgres-primary, redis, runtime-ruby, hub-*, …      │
│  /persist     : writable — PKI, postgres data, overlay upper dir     │
└──────────────────────────────────────────────────────────────────────┘
```

**Layered, not flattened.** Keep the erofs blobs as-is and let the initramfs assemble
the overlay at boot (the logic `ComposeForPivot` already implements). Flattening into
one rootfs is simpler to boot but throws away per-layer fs-verity **and** the agent's
runtime layer-swap (every update would force a full image re-bake). bootc (family 6)
is inherently layered/ostree-style and fits this model directly.

### Boot flow (identical on every provider)

```
firmware → GRUB (on the disk) → vmlinuz + initramfs (on the disk)
  → agent `boot`: resolve identity (cloud-metadata | fw-cfg | cmdline) → enroll if no PKI
  → ComposeForPivot: mount on-disk erofs layers → overlay union at /sysroot
       → write identity + enable native units into the union → switch_root /sysroot
  → systemd-in-union (modular / ) → agent `service` reconciles RUNTIME updates
```

Only the **layer source** differs from `direct_kernel`: instead of fetch-over-OCI or
the libvirt 9p share, the initramfs reads the erofs blobs from the image's own `layers`
area. Everything downstream (overlay, identity, native units, `switch_root`) is unchanged.

### The one new agent capability

`ComposeForPivot` currently obtains layers two ways (OCI fetch; 9p prepare-root). Add a
third **on-disk `LayerSource`** that enumerates the baked erofs blobs from a known
partition/dir. Small, additive, and keeps the assemble/pivot code identical.

### What gets baked

**Recommended: the full resolved union for a template** (e.g. all `powernode-hub`
modules). That makes the image **boot fully offline** — the property air-gapped
managed-children need — with no first-boot network dependency. (Alternative: bake only
the `base.os` layers and let the agent fetch the rest at first boot; smaller image, but
needs network, defeating the offline goal.)

### Update model — modularity is preserved

The baked union is the **offline boot baseline**, not a frozen image. After
`switch_root`, the agent runs as `service` and reconciles exactly as it does today: it
pulls **new/updated** erofs layers over the network and overlays them. So routine
module updates **do not require re-baking**; you re-bake periodically (via the
disk-image CI) only to refresh the baseline (kernel/security/base-os). Per-layer
fs-verity + cosign survive end-to-end.

## New work — the bake step (CI)

Extend `build-disk-image.yaml` / the initramfs builder so that, given a **template**:

1. Resolve the template's module set (the existing dependency resolver, incl. `base.os`).
2. Pull each module's signed erofs from the module registry.
3. Assemble GRUB + kernel + initramfs + the erofs `layers` + a `/persist` partition into
   a partitioned image; emit the relevant families (qcow2, `.img`, bootc-OCI, ISO/iPXE).
4. cosign-sign and publish via the existing disk-image CI → `DiskImagePublication`,
   wiring `ProviderRegion.machine_image` to the published ref per provider.

## Per-provider delivery

| Provider | Family | Import path |
|---|---|---|
| PVE | qcow2 (or `direct_kernel` for dev) | storage import; `machine_image` = qcow2 ref |
| AWS | raw `.img` | import as snapshot → register AMI |
| GCP | raw `.img`/tar | `images create --source-disk`/RAW import |
| Azure | VHD | managed image |
| Bare metal | `.img` / ISO / iPXE | USB/SD `dd`, IPMI virtual media, or netboot |
| bootc hosts | OCI (family 6) | `bootc switch` / container-native |

## Identity across providers

The agent's `identity.Resolver` chain (`cmdline → fwcfg → claim → cloud → local`)
already includes a **cloud-metadata** source, so enrollment works uniformly: cloud
instances self-identify from instance metadata, PVE via fw-cfg, bare metal via cmdline
or the claim flow. No new identity mechanism required.

## Relationship to current work

- **Prerequisite 1 — real `powernode-system-base`:** the union's agent layer must
  contain `/sbin/powernode-agent` (the CI go-toolchain fix, run 382).
- **Prerequisite 2 — pivot P2:** prove assemble+`switch_root` once on `direct_kernel`
  before wrapping it in a disk image.
- The bake step then reuses that proven path verbatim. Nothing in P1/P2 is wasted.

## Decisions (recommended defaults)

1. **Layered**, not flattened — preserve fs-verity + runtime modularity; reuse the
   initramfs assembly. bootc is the natural layered target.
2. **Bake the full per-template union** — offline-bootable.
3. **Primary targets:** bootc-OCI (6) + qcow2 (5) + raw `.img`→AMI (2).
4. **Migration:** keep `cloud_init`/chroot as a legacy fallback; flip the default
   `boot_mode` to the baked image **per provider**, as each is validated.

## Phased plan

| Phase | Deliverable |
|---|---|
| BAKE-0 | Prereqs green: system-base real (run 382), pivot P2 proven |
| BAKE-1 | Agent on-disk `LayerSource` for `ComposeForPivot` (+ tests) |
| BAKE-2 | Bake step in CI (resolve template union → qcow2); boot on PVE → modular `/`, offline |
| BAKE-3 | AWS `.img`→AMI import + boot + enroll via cloud-metadata |
| BAKE-4 | bootc-OCI (6) + GCP/Azure |
| BAKE-5 | Flip default `boot_mode` per provider once validated |

## Open questions

- **bootc vs. custom GRUB+initramfs** as the canonical boot path (bootc gives
  transactional updates + OCI-native delivery; custom keeps full control of the pivot).
- **Stateful data** (`/persist` sizing; postgres data dir placement) across re-bakes.
- **Image-level signing/verification** vs. relying on per-layer cosign/fs-verity.
- Full-union image **size** vs. a thin base + curated first-boot fetch for large stacks.

## Note

`DISK_IMAGE_CI.md` still describes the module blob as "composefs" — that predates the
erofs migration (commit `80b57be`) and should be refreshed alongside this work.

_Last verified: 2026-06-03_
