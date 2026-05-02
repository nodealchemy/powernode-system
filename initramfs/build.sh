#!/usr/bin/env bash
# Multi-arch boot artifact builder for the Powernode system extension.
#
# Reference: Golden Eclipse plan M3. Produces six artifact families per arch:
#   1. kernel + initramfs bundle (PXE/iPXE network boot, libvirt direct)
#   2. raw disk image (.img — USB stick / SD card / direct dd)
#   3. ISO 9660 image (.iso — DVD/USB, IPMI virtual media)
#   4. iPXE chainload script (.ipxe — network-boot entry point)
#   5. cloud qcow2 image (.qcow2 — libvirt/QEMU pre-baked rootfs)
#   6. OCI image (bootc-compatible, container-image-as-OS)
#
# Usage:
#   ./build.sh --arch amd64 [--variants kernel-initrd,raw,iso,ipxe,qcow2,oci]
#   ./build.sh --arch arm64 [--variants ...]
#
# All variants are built by default. Use --variants to restrict.
#
# Outputs land at: build/<arch>/<variant>/...
#
# Pinning: BASE_IMAGE_DIGEST + KERNEL_PACKAGE_VERSION + COMPOSEFS_TOOLS_VERSION
# are injected from CI workflow inputs to honor the M1 reproducibility gate.
# Re-running the build with the same pins on the same source must produce
# identical SHA-256 digests.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_VARIANTS="kernel-initrd,raw,iso,ipxe,qcow2,oci"
readonly DEFAULT_BASE_IMAGE="ubuntu@sha256:placeholder-pin-via-ci-input"

ARCH=""
VARIANTS="${DEFAULT_VARIANTS}"
BASE_IMAGE_DIGEST="${BASE_IMAGE_DIGEST:-${DEFAULT_BASE_IMAGE}}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/build}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --arch {amd64|arm64} [options]

Required:
  --arch         Target architecture (amd64 or arm64)

Optional:
  --variants     Comma-separated list of variants to build.
                 Default: ${DEFAULT_VARIANTS}
  --output-dir   Output root (default: \${SCRIPT_DIR}/build)
  --base-image   Pinned base image digest (default: \$BASE_IMAGE_DIGEST env)
  --help         Show this help

Examples:
  $(basename "$0") --arch amd64
  $(basename "$0") --arch arm64 --variants kernel-initrd,iso
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)        ARCH="$2"; shift 2 ;;
    --variants)    VARIANTS="$2"; shift 2 ;;
    --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
    --base-image)  BASE_IMAGE_DIGEST="$2"; shift 2 ;;
    --help|-h)     usage 0 ;;
    *)             echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -z "${ARCH}" ]] && { echo "ERROR: --arch is required" >&2; usage 1; }
[[ "${ARCH}" =~ ^(amd64|arm64)$ ]] || { echo "ERROR: --arch must be amd64 or arm64" >&2; exit 1; }

readonly ARCH_OUT="${OUTPUT_DIR}/${ARCH}"
mkdir -p "${ARCH_OUT}"

log() { echo "[$(date -Iseconds)] [$ARCH] $*"; }

# ── Variant: kernel + initramfs bundle ─────────────────────────────────────
build_kernel_initrd() {
  log "Building kernel + initramfs (dracut)…"
  local out="${ARCH_OUT}/kernel-initrd"
  mkdir -p "${out}"

  # Kernel module list per architecture.
  local arch_conf="${SCRIPT_DIR}/dracut.conf.d/powernode-${ARCH}.conf"
  local shared_conf="${SCRIPT_DIR}/dracut.conf.d/powernode.conf"

  # Compose dracut module path so /sbin/ipn-agent is embedded into initramfs
  # along with the powernode module-setup hook (modules.d/90powernode/).
  if ! command -v dracut >/dev/null 2>&1; then
    log "WARN: dracut not in PATH — emitting placeholder for offline planning"
    echo "placeholder kernel for ${ARCH}" >"${out}/kernel"
    echo "placeholder initramfs for ${ARCH}" >"${out}/initramfs.cpio.zst"
    return 0
  fi

  local kver
  kver="$(cd /lib/modules && ls -1 | head -n1)"
  if [[ -z "${kver}" ]]; then
    log "ERROR: no kernel modules available under /lib/modules" >&2
    return 1
  fi

  # The agent binary must already be staged at scripts/ipn-agent (built by
  # the agent CI in extensions/system/agent/.gitea/workflows/build.yaml).
  if [[ ! -x "${SCRIPT_DIR}/scripts/ipn-agent-${ARCH}" ]]; then
    log "WARN: agent binary missing for ${ARCH} — embedding placeholder shim"
    mkdir -p "${SCRIPT_DIR}/scripts"
    cat >"${SCRIPT_DIR}/scripts/ipn-agent-${ARCH}" <<'SHIM'
#!/bin/sh
echo "[powernode-shim] ipn-agent placeholder — replace with cross-compiled binary"
exec /bin/sh
SHIM
    chmod +x "${SCRIPT_DIR}/scripts/ipn-agent-${ARCH}"
  fi
  cp "${SCRIPT_DIR}/scripts/ipn-agent-${ARCH}" /tmp/ipn-agent

  local conf_args=("-c" "${shared_conf}")
  [[ -f "${arch_conf}" ]] && conf_args+=("-c" "${arch_conf}")

  dracut \
    "${conf_args[@]}" \
    --modules "powernode" \
    --kver "${kver}" \
    --include "/tmp/ipn-agent" "/sbin/ipn-agent" \
    --compress zstd \
    --force \
    "${out}/initramfs.cpio.zst"

  cp "/boot/vmlinuz-${kver}" "${out}/kernel"

  sha256sum "${out}/kernel" "${out}/initramfs.cpio.zst" >"${out}/SHA256SUMS"
  log "kernel-initrd ✓ at ${out}"
}

# ── Variant: raw disk image (UEFI ESP + ext4 boot + ext4 persist) ──────────
build_raw() {
  log "Building raw disk image…"
  local out="${ARCH_OUT}/raw"
  mkdir -p "${out}"
  bash "${SCRIPT_DIR}/images/raw/build-raw.sh" --arch "${ARCH}" --output "${out}/installer.img"
  sha256sum "${out}/installer.img" >"${out}/SHA256SUMS" 2>/dev/null || true
  log "raw ✓ at ${out}"
}

# ── Variant: ISO (xorriso, hybrid EFI+BIOS for amd64; pure UEFI for arm64) ──
build_iso() {
  log "Building ISO…"
  local out="${ARCH_OUT}/iso"
  mkdir -p "${out}"
  bash "${SCRIPT_DIR}/images/iso/build-iso.sh" --arch "${ARCH}" --output "${out}/installer.iso"
  sha256sum "${out}/installer.iso" >"${out}/SHA256SUMS" 2>/dev/null || true
  log "iso ✓ at ${out}"
}

# ── Variant: iPXE chainload script (server-rendered template) ──────────────
build_ipxe() {
  log "Building iPXE chainload template…"
  local out="${ARCH_OUT}/ipxe"
  mkdir -p "${out}"
  cp "${SCRIPT_DIR}/images/ipxe/template.ipxe.erb" "${out}/template.ipxe.erb"
  log "ipxe ✓ template copied to ${out} — server's NetbootService renders per-instance"
}

# ── Variant: qcow2 pre-baked cloud image ───────────────────────────────────
build_qcow2() {
  log "Building qcow2 cloud image…"
  local out="${ARCH_OUT}/qcow2"
  mkdir -p "${out}"
  bash "${SCRIPT_DIR}/images/qcow2/build-qcow2.sh" --arch "${ARCH}" --output "${out}/cloud.qcow2"
  sha256sum "${out}/cloud.qcow2" >"${out}/SHA256SUMS" 2>/dev/null || true
  log "qcow2 ✓ at ${out}"
}

# ── Variant: OCI image (bootc-compatible) ──────────────────────────────────
build_oci() {
  log "Building OCI bootc image…"
  local out="${ARCH_OUT}/oci"
  mkdir -p "${out}"
  if ! command -v buildah >/dev/null 2>&1; then
    log "WARN: buildah not installed — OCI build skipped (install buildah for bootc)"
    return 0
  fi
  buildah bud \
    --platform "linux/${ARCH}" \
    --build-arg "BASE_IMAGE_DIGEST=${BASE_IMAGE_DIGEST}" \
    -t "powernode-bootc:${ARCH}" \
    -f "${SCRIPT_DIR}/images/oci/Containerfile" \
    "${SCRIPT_DIR}/images/oci"
  log "oci ✓ tag=powernode-bootc:${ARCH}"
}

# ── Dispatch ───────────────────────────────────────────────────────────────
log "Starting build (variants: ${VARIANTS})"

IFS=',' read -ra VARIANT_LIST <<<"${VARIANTS}"
for v in "${VARIANT_LIST[@]}"; do
  case "$v" in
    kernel-initrd) build_kernel_initrd ;;
    raw)           build_raw ;;
    iso)           build_iso ;;
    ipxe)          build_ipxe ;;
    qcow2)         build_qcow2 ;;
    oci)           build_oci ;;
    *)             log "WARN: unknown variant '$v' — skipped" ;;
  esac
done

# ── Reproducibility manifest ──────────────────────────────────────────────
{
  echo "# Powernode bootloader build manifest"
  echo "arch=${ARCH}"
  echo "base_image=${BASE_IMAGE_DIGEST}"
  echo "variants=${VARIANTS}"
  echo "build_time=$(date -Iseconds)"
  echo "git_sha=$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || echo 'unknown')"
} >"${ARCH_OUT}/MANIFEST"

log "Build complete: ${ARCH_OUT}"
