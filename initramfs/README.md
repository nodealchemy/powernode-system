# Powernode Initramfs Builder

Multi-arch reproducible boot artifact builder for Powernode nodes. Produces
six artifact families per architecture (amd64, arm64) per release, each suitable
for a different boot path: PXE / iPXE chainload, ISO install media, raw disk
image flashing, qcow2 cloud upload, OCI bootc registry push, and SBC-specific
images (Raspberry Pi 4, generic UEFI ARM).

This builder implements **M3** of the Golden Eclipse roadmap. The on-node
runtime that consumes these artifacts is the Go agent at `../agent/`.

---

## Layout

```
initramfs/
├── build.sh              # Top-level build orchestrator (12K)
├── dracut.conf.d/        # Dracut module + driver configuration per arch
│   ├── powernode.conf            # Common config
│   ├── powernode-amd64.conf      # x86_64-specific
│   └── powernode-arm64.conf      # ARM64-specific
├── modules.d/
│   └── 90powernode/      # Custom dracut module: agent init, mount orchestration
├── scripts/              # Architecture-specific helper scripts
│   └── powernode-agent-amd64
├── images/               # Build artifact landing zone (gitignored output)
│   ├── disk-image-arm64-uefi/    # Generic UEFI ARM (Pi 5, Ampere, SBCs)
│   ├── disk-image-rpi4/          # Raspberry Pi 4 (firmware + boot partition)
│   ├── ipxe/                     # iPXE chainload bundle
│   ├── iso/                      # Hybrid BIOS+UEFI ISO
│   ├── oci/                      # bootc-compatible OCI artifact
│   ├── qcow2/                    # Cloud / hypervisor disk
│   └── raw/                      # Raw disk image
├── build/                # Per-arch staging areas (gitignored)
└── .gitea/               # CI workflow definitions (build pipeline)
```

---

## Usage

### Local build (single arch + variant)

```bash
# Build amd64 ipxe bundle
ARCH=amd64 VARIANT=ipxe ./build.sh

# Build arm64 raw disk image
ARCH=arm64 VARIANT=raw ./build.sh

# Build everything for one arch
ARCH=amd64 ./build.sh    # cycles through all 6 variants
```

Outputs land under `images/<variant>/<arch>/` with checksums and a
manifest describing the build inputs.

### CI build (all artifacts, both archs, signed)

The `.gitea/workflows/build-disk-image.yaml` workflow (and the platform-level
counterpart at `extensions/system/.gitea/workflows/build-disk-image.yaml`)
runs on every push to the system extension's `main` branch. It:

1. Pins inputs for reproducibility (see "Reproducibility" below).
2. Builds all six variants × both archs in parallel.
3. Computes per-artifact SHA-256 + fs-verity Merkle root hashes.
4. Pushes the OCI bootc variant to the platform's container registry
   (`git.ipnode.org`) with cosign signing via Sigstore Fulcio (no
   long-lived keys; ephemeral OIDC-bound certs).
5. Uploads non-OCI variants as Gitea release artifacts.
6. Fires the platform's disk-image-built webhook (`POST
   /api/v1/system/webhooks/disk_image_built`) with HMAC-validated metadata so
   the platform creates `System::DiskImagePublication` rows.

---

## Artifact families

| Variant | Boot path | Use case |
|---|---|---|
| `kernel-initrd` | Direct kernel boot (QEMU `-kernel` + `-initrd`) | Local QEMU thin slice (M4), CI smoke tests |
| `raw` | `dd` → block device | First-boot bare-metal flashing, USB stick |
| `iso` | El Torito hybrid BIOS+UEFI | Install media, ISO mount in cloud consoles |
| `ipxe` | iPXE chainload from PXE server | Network boot, `/api/v1/system/netboot/:instance_id/script.ipxe` |
| `qcow2` | Hypervisor disk import | Cloud upload (AWS import-image, GCP, etc.), libvirt domains |
| `oci` | bootc + podman-bootc-fetch | Container-based boot stacks (Fedora CoreOS-style) |
| `disk-image-rpi4` | Raspberry Pi 4 SD card | Bootloader/EEPROM + boot partition + rootfs |
| `disk-image-arm64-uefi` | Generic ARM UEFI flashing | Pi 5, Ampere, ARM SBCs, ARM cloud instances |

---

## Boot pipeline (what happens on the node)

```
firmware → bootloader (GRUB / U-Boot / iPXE)
       → linux kernel (signed, lockdown=integrity, IMA/EVM enabled)
       → initramfs (dracut + 90powernode module)
            ├── claim node identity (cloud metadata / fw-cfg / local UUID)
            ├── mount composefs lower (verified via fs-verity)
            ├── stack overlay/bind for module union
            ├── pivot to real root
            └── launch powernode-agent
       → systemd multi-user.target
       → powernode-agent
            ├── enroll (mTLS via bootstrap token → node certificate)
            ├── pull modules (OCI digest + cosign signature verification)
            ├── attach modules (mount + apply SELinux/AppArmor profile)
            └── heartbeat + lease loop
```

The 90powernode dracut module provides the initramfs-stage logic: identity,
union mount, agent launch. The Go agent in `../agent/` provides everything
post-pivot.

---

## Reproducibility

Two builds of the same source MUST produce byte-identical artifacts (matching
`oci_digest` and `fsverity_root_hash`). Inputs pinned by CI:

- **Base image**: `ubuntu@sha256:<digest>` (NOT `ubuntu:24.04` — the digest
  changes when Canonical rebuilds)
- **Debian / Ubuntu snapshot URLs**: `snapshot.ubuntu.com/ubuntu/<timestamp>/`
  — locks package versions to a moment in time
- **composefs-tools version**: pinned in CI env (currently `1.0.x`)
- **Kernel package**: explicit `linux-image-X.Y.Z-N-generic` pin
- **Dracut version**: from the same Ubuntu snapshot
- **mmdebstrap** (replaces multistrap): pinned

Verifiable via the build manifest emitted into each artifact directory
(`build-manifest.json`).

---

## Dracut configuration

Three files in `dracut.conf.d/` get copy-merged into the initramfs build:

- `powernode.conf` — common modules (composefs, overlayfs, virtio drivers,
  90powernode), kernel cmdline defaults
- `powernode-amd64.conf` — x86 firmware drivers (intel-microcode, amd-microcode,
  i915, amdgpu)
- `powernode-arm64.conf` — ARM firmware blobs (raspberrypi-firmware for Pi
  variants, generic UEFI fallback)

Modules forced into the initramfs include:

- `composefs` — verified-mount lower layer
- `overlayfs` — module union mount
- `virtio_pci` / `virtio_blk` / `virtio_net` — hypervisor I/O
- `9p` (kernel) + `9p_virtio` — virtio-fw-cfg seed transport (used by
  `LocalQemuProvider` in M4)

---

## 90powernode dracut module

Custom dracut module providing initramfs-stage Powernode behavior. Mounted
during `pre-mount` and `mount` stages. Responsibilities:

1. **Identity claim**: try in order — cloud metadata IMDS, virtio fw-cfg,
   local UUID file at `/etc/powernode/local-id`. First success wins.
2. **Composefs lower mount**: compute fs-verity Merkle root, mount the
   verified composefs image as the lower layer.
3. **Overlay stacking**: assemble per-module overlay layers ordered by
   `effective_priority` (computed server-side from the union of `node_module`
   `priority` and category sibling positions).
4. **Bind mounts**: any 9p / virtio-fs paths from the host (typically the
   per-instance seed bundle).
5. **Pivot**: `switch_root` into the unioned root.

Source files live under `modules.d/90powernode/`. Each is shell with
strict-mode set; runtime constraints are tight (no Python, no Ruby — must
work against busybox + the few binaries dracut copies in).

---

## M3.5 Real-Hardware Verification (open milestone)

Blocked on hardware availability. Verification steps for each target platform:

### x86 server

1. Flash `images/raw/amd64/disk.raw` to a USB stick.
2. Boot a target server (UEFI or BIOS); kernel cmdline as documented in
   `docs/SMOKE_TEST.md`.
3. Verify the agent enrolls with the platform (look for `node_certificate`
   row + first `fleet_event` of kind `instance.enrolled`).
4. Attach a module (e.g., `nginx` from `templates/example-modules/nginx/`).
5. Verify the module appears mounted under `/var/lib/powernode/modules/<name>/`
   and the systemd unit (if any) starts.

### ARM SBC (Raspberry Pi 4)

1. Flash `images/disk-image-rpi4/disk.img` to an SD card.
2. Insert into Pi 4, power on.
3. Same verification as above. Pi-specific: check that the bootloader picks
   up the firmware blob in the boot partition.

### ARM UEFI server (Ampere / Pi 5)

1. Flash `images/disk-image-arm64-uefi/disk.img`.
2. Boot via UEFI (note: boot order may need shell intervention on first boot).
3. Same verification.

Each target gets a dedicated runbook section once executed for the first
time.

---

## Smoke test quickstart (no hardware)

See `../docs/SMOKE_TEST.md` for the full M3+M4 QEMU thin slice.

Short version:

```bash
cd extensions/system/initramfs
ARCH=amd64 VARIANT=kernel-initrd ./build.sh

# Then in the platform working tree
cd extensions/system/server
bundle exec rspec spec/services/system/providers/local_qemu_provider_spec.rb
```

For a real boot (requires libvirt + sudo):

```bash
cd extensions/system/server
POWERNODE_LIBVIRT_MODE=real bundle exec rails runner \
  'System::Providers::LocalQemuProvider.smoke_test!'
```

---

## Reference

- Build script: `build.sh` (12K — start here when adding new variants)
- Golden Eclipse plan M3: `~/.claude/plans/we-are-working-on-golden-eclipse.md`
- Smoke test: `../docs/SMOKE_TEST.md`
- CI workflow: `.gitea/workflows/build-disk-image.yaml`
- Architecture overview: `../docs/ARCHITECTURE.md`
- Go agent (post-pivot runtime): `../agent/README.md`
