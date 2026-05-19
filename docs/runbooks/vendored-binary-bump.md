# Vendored Binary Bump Playbook

**Audience:** platform maintainers updating an upstream dependency the platform ships with itself.
**Prerequisites:** clean working tree on `develop`; ability to run `make` in `agent/`; for ARM-only items, access to a Pi 4 or QEMU-aarch64 for boot smoke.
**Runtime:** 15–60 min depending on item + smoke depth.

Why this exists: per [`feedback_no_host_dependencies.md`](../../../../../.claude/projects/-home-rett-Drive-Projects-powernode-platform/memory/feedback_no_host_dependencies.md) the platform **ships** the external binaries it depends on instead of `apt install`-ing them on target nodes. Each pinned item needs a clear, reviewable bump path. This runbook is that path.

## Inventory of vendored items

| Item | Where pinned | What ships | Bump command |
|---|---|---|---|
| **Traefik** | `agent/Makefile:64` → `TRAEFIK_VERSION` | `dist/powernode-reverse-proxy-linux-{amd64,arm64}` | `make -C agent bump-traefik NEW=vX.Y.Z` |
| **rpi4-firmware** | `templates/example-modules/rpi4-firmware/manifest.yaml` → `build.firmware_ref` | `/boot/firmware/*` blobs in the rpi4 disk image | manual edit + smoke (see below) |
| **dracut** | `initramfs/.gitea/workflows/build.yaml:53` → `APT_SNAPSHOT` | initramfs builder version (build-host only) | manual edit + reproducibility re-run |
| **Kernel** | `initramfs/build.sh` → host's `/boot/vmlinuz-*` selected via `APT_SNAPSHOT` pin | kernel image bundled into the initramfs artifact | manual edit + boot smoke |
| **k3s** (Phase 3, deferred) | `modules/powernode-k3s-binary/manifest.yaml` → `build.k3s_version` | `/usr/local/bin/k3s` on cluster nodes | playbook to be added when the module ships |

## Generic procedure

For every bump, regardless of item:

1. **Identify the upstream release.** Read the upstream's CHANGELOG / release notes. Confirm:
   - No breaking changes that affect the platform's usage (Traefik config flags, kernel ABI, etc.)
   - Security advisories addressed (worth bumping for)
   - Asset names match the bump tooling's expectations (e.g. `traefik_<ver>_linux_<arch>.tar.gz`)
2. **Verify upstream integrity.** Where the upstream publishes signatures (cosign, gpg), validate them before consuming. Bump tooling does basic asset-presence checks but doesn't replace cryptographic verification.
3. **Edit the pin.** One pin per bump. Never bundle a Traefik bump with a kernel bump in the same commit — they have different smoke surfaces.
4. **Smoke test.** Per-item smoke below.
5. **Commit + open PR.** Subject line: `chore(<item>): bump <item> <old> → <new>`. Body: changelog summary + smoke evidence + rollback plan.
6. **Tag a release** if the bump is platform-critical (security CVE, breaking upstream removal).

## Traefik

```bash
make -C extensions/system/agent bump-traefik NEW=v3.3.5
```

The target:
- Verifies `vX.Y.Z` exists at `github.com/traefik/traefik/releases`
- Verifies both `linux/amd64` and `linux/arm64` assets are present
- Rewrites `TRAEFIK_VERSION` in `agent/Makefile` via `sed -i.bak` then removes the backup
- Runs `make clean-traefik` + `make vendor-traefik` to download + install
- Prints next-step verification commands

**Smoke (manual):**

```bash
file extensions/system/agent/dist/powernode-reverse-proxy-linux-amd64
# Expect: ELF 64-bit LSB executable, x86-64, statically linked
extensions/system/agent/dist/powernode-reverse-proxy-linux-amd64 version
# Expect: the new version string

# End-to-end: deploy powernode-reverse-proxy module to a NodeInstance and
# verify the traefik service starts + serves :80 / :443. See
# extensions/system/modules/powernode-reverse-proxy/manifest.yaml for the
# service definition.
```

**Rollback:**

```bash
make -C extensions/system/agent bump-traefik NEW=<previous-version>
# OR: git revert the bump commit + make clean-traefik && make vendor-traefik
```

**Failure modes:**

| Symptom | Diagnosis | Fix |
|---|---|---|
| `FATAL: upstream release vX.Y.Z not found` | Wrong tag (typo, missing `v` prefix, doesn't exist yet) | Re-check `github.com/traefik/traefik/releases` |
| `FATAL: linux/<arch> asset missing` | Upstream changed asset naming | Inspect `checksums.txt` URL manually; update `bump-traefik` target if naming convention changed |
| `vendor-traefik-amd64` fails after bump | Tarball layout changed (no top-level `traefik` binary) | Examine extracted contents; update `vendor-traefik-<arch>` recipes |

## rpi4-firmware

The firmware blobs come from `github.com/raspberrypi/firmware` at a pinned commit. The repo is huge (5+ GB); the build pulls just the boot files via raw GitHub URLs.

**Procedure:**

1. Pick the new ref:
   ```bash
   curl -sSL https://api.github.com/repos/raspberrypi/firmware/tags | jq -r '.[].name' | head
   ```
2. Edit `extensions/system/templates/example-modules/rpi4-firmware/manifest.yaml`:
   ```yaml
   build:
     firmware_ref: "<new-ref>"   # was "1.20240306"
   ```
3. Rebuild the rpi4 disk image:
   ```bash
   cd extensions/system/initramfs
   POWERNODE_OFFLINE_DEV=1 ./build.sh --arch arm64 --variants kernel-initrd,disk-image-rpi4
   ```
4. Boot smoke (one of):
   - **Real Pi 4**: flash `build/arm64/disk-image-rpi4/powernode-rpi4.img` to SD card, boot, verify SSH access + agent heartbeat
   - **QEMU aarch64**: use the bare-metal physical-device claim smoke (`smoke_test_bare_metal_claim.rb`) — see [SMOKE_TEST.md §"Pass 8 — Hardware / CI extras"](../SMOKE_TEST.md#pass-8--hardware--ci-extras)

**Why bump?**

- New Pi 4 silicon revisions ship requiring newer GPU firmware
- Security fix in the bootloader
- New kernel requires newer GPU bridge

**Rollback:** revert the manifest commit. Old Pi 4 silicon usually stays compatible with older firmware.

## dracut (build-host only)

`dracut` runs only on the build host (CI runner), never on a target node. Pinning happens via APT snapshot timestamp.

**Procedure:**

1. Find the snapshot timestamp at <https://snapshot.ubuntu.com/> (or your mirror)
2. Edit `extensions/system/initramfs/.gitea/workflows/build.yaml:53`:
   ```yaml
   APT_SNAPSHOT: ${{ inputs.apt_snapshot || '<new-YYYYMMDDTHHMMSSZ>' }}
   ```
3. Trigger the M3 reproducibility gate via `workflow_dispatch` with both `base_image_digest` + `apt_snapshot` inputs; gate must pass (two builds, byte-identical `build-manifest.json`)

**Rollback:** revert the workflow commit.

## Kernel

Kernel selection happens in `build_kernel_initrd()` (`initramfs/build.sh:79-110`): prefers `KERNEL_VERSION` env, then running kernel, then newest kernel with modules + `/boot/vmlinuz-*`.

**Procedure:**

1. Decide the desired pin:
   - For HWE upgrades, pick the new Ubuntu HWE kernel ABI (e.g. `6.11.0-13-generic`)
   - For LTS, pick the matching GA kernel
2. Edit `extensions/system/initramfs/.gitea/workflows/build.yaml` to set `KERNEL_VERSION` env (or change `APT_SNAPSHOT` so the apt index advances)
3. Re-run the build pipeline
4. **Boot smoke is mandatory** for kernel bumps:
   - QEMU boot (cheap, every PR)
   - Real-hardware boot (release gate, per `project_smoke_test_state.md`)

**Why this needs more care than Traefik:** a bad kernel bumps bricks every node booting the new image. Treat kernel bumps as separate PRs with explicit release-engineer sign-off.

**Rollback:** revert the pin commit; the prior kernel image is still in the artifact store (per `disk_image_retention_count` default of 5).

## k3s (deferred — Phase 3)

When the `powernode-k3s-binary` module ships (planned: package the k3s binary as a versioned NodeModule so the on-node install path doesn't depend on a `curl | sh` of an upstream artifact), add a `k3s` section here following the Traefik pattern: pin in module manifest's `build.k3s_version`, smoke via [`tutorials/04-k3s-cluster.md`](../tutorials/04-k3s-cluster.md), rollback by reverting the module-version promotion.

Until then, k3s on-node is installed via `curl | sh` (`agent/internal/k3sd/shell_applier.go:113–131`). The migration recipe will replace that with a `manifest.Service` entry pointing at the module-bundled binary path.

## Related

- The platform's "ship-with-platform" rule this playbook serves: external binaries the platform depends on must ship WITH the platform (Ruby gem, Go binary in `agent/cmd/`, or vendored release artifact via this playbook) — never as a host-side install (apt/brew).
- [`../MODULE_MANIFEST_COMPLETE_SCHEMA.md`](../MODULE_MANIFEST_COMPLETE_SCHEMA.md) — manifest `build:` block fields
- [`../../initramfs/build.sh`](../../initramfs/build.sh) — kernel selection logic
- [`../../agent/Makefile`](../../agent/Makefile) — Traefik + ACME + agent build targets
- Related forthcoming work: k3s on-node bundling (covered above under "k3s — deferred Phase 3"), reproducibility gate (M3 byte-identical builds via APT snapshot pinning — already wired into the build workflow).
