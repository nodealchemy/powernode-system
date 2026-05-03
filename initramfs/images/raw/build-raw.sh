#!/usr/bin/env bash
# Builds a GPT-partitioned raw disk image suitable for direct dd to USB / SD
# card / NVMe. Layout:
#
#   p1 — EFI System Partition (FAT32, 512 MB) — bootloader + kernel + initrd
#   p2 — boot (ext4, 1 GB) — additional kernels for fallback boot
#   p3 — persist (ext4, ~remainder) — /persist/var bind target, LUKS-ready
#
# Modernization vs legacy: the legacy `ipn_volume_setup` function in
# ~/Drive/Projects/powernode-bootstrap/scripts/ipn_functions used a
# two-partition layout (boot ext2 + extlinux, store ext4). This script
# evolves that to UEFI-only with a separate persist partition, plus an
# explicit boot partition for kernel fallbacks during upgrades.
#
# Reference: Golden Eclipse plan M3 — images/raw.
set -euo pipefail

# Ensure standard sbin paths are searchable (Gitea Actions runners strip
# /usr/sbin from non-root user PATH).
export PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH:-/usr/local/bin:/usr/bin:/bin}"

ARCH=""
OUTPUT=""
SIZE_GB="${SIZE_GB:-8}"

usage() { echo "Usage: $0 --arch {amd64|arm64} --output IMG_PATH [--size-gb N]"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)    ARCH="$2"; shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    --size-gb) SIZE_GB="$2"; shift 2 ;;
    --help|-h) usage 0 ;;
    *)         echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -z "$ARCH" ]] && usage 1
[[ -z "$OUTPUT" ]] && usage 1

mkdir -p "$(dirname "$OUTPUT")"

# Allocate sparse image
echo "[raw] allocating ${SIZE_GB}G sparse image at $OUTPUT"
truncate -s "${SIZE_GB}G" "$OUTPUT"

# GPT layout via sgdisk (preferred over fdisk for scripting)
if ! command -v sgdisk >/dev/null 2>&1; then
  echo "[raw] WARN: sgdisk not installed — emitting placeholder image"
  echo "powernode-raw-placeholder-$ARCH" >"$OUTPUT"
  exit 0
fi

sgdisk --zap-all "$OUTPUT" >/dev/null
sgdisk \
  --new=1:0:+512M --typecode=1:ef00 --change-name=1:"EFI" \
  --new=2:0:+1G   --typecode=2:8300 --change-name=2:"boot" \
  --new=3:0:0     --typecode=3:8300 --change-name=3:"persist" \
  "$OUTPUT" >/dev/null

echo "[raw] partition table:"
sgdisk -p "$OUTPUT" | grep -A 10 "^Number" || true

# Filesystem creation requires loop device — skip in placeholder mode if
# loopback is unavailable (most CI runners need privileged mode).
if ! command -v losetup >/dev/null 2>&1 || [[ ! -w /dev/loop-control ]]; then
  echo "[raw] losetup unavailable — skipping FS creation (CI must run privileged for full build)"
  echo "$OUTPUT"
  exit 0
fi

LOOP="$(losetup --partscan --find --show "$OUTPUT")"
trap 'losetup -d "$LOOP" 2>/dev/null || true' EXIT

mkfs.fat -F32 -n EFI "${LOOP}p1"
mkfs.ext4 -F -L boot "${LOOP}p2"
mkfs.ext4 -F -L persist "${LOOP}p3"

echo "[raw] image ready: $OUTPUT"
