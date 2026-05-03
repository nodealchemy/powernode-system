#!/usr/bin/env bash
# Builds a generic arm64 UEFI-bootable disk image for the physical-device
# claim flow. Targets Pi 5 (with UEFI Pi firmware), Ampere Altra boards,
# and any other arm64 SBC that boots via standard EFI.
#
# Plan: docs/plans/wondrous-yawning-anchor.md §3 (build pipeline).
#
# This wraps build-raw.sh — the existing GPT layout (EFI+boot+persist)
# is already correct for UEFI. We then mount the EFI partition and layer
# in identity.cfg + powernode-ca.pem so the agent's BootIdentityStrategy
# can read its config from /boot/identity.cfg after init-powernode.sh
# mounts the boot partition.
#
# Why a separate script vs raw: raw produces a generic install image,
# but the disk-image-* family targets the operator-flash workflow
# specifically — same artifacts, different identity payload + claim
# placeholder cmdline. Keeping them separate lets the platform stamp
# disk-image artifacts with operator-facing metadata (this is for
# claim-flow Path C) without polluting the more-general raw build.
set -euo pipefail

ARCH="arm64"
OUTPUT=""
SIZE_GB="${SIZE_GB:-4}"
PLATFORM_URL="${PLATFORM_URL:-https://platform.example.com}"
CA_PEM_FILE="${CA_PEM_FILE:-}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --output IMG_PATH [options]

Required:
  --output             Destination .img path

Optional:
  --size-gb N          Total image size (default: 4)
  --platform-url URL   Baked into identity.cfg (default:
                       https://platform.example.com)
  --ca-pem-file PATH   Copied to /powernode-ca.pem on EFI partition.
  --help
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)        OUTPUT="$2"; shift 2 ;;
    --size-gb)       SIZE_GB="$2"; shift 2 ;;
    --platform-url)  PLATFORM_URL="$2"; shift 2 ;;
    --ca-pem-file)   CA_PEM_FILE="$2"; shift 2 ;;
    --help|-h)       usage 0 ;;
    *)               echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -z "$OUTPUT" ]] && usage 1
mkdir -p "$(dirname "$OUTPUT")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_BUILDER="${SCRIPT_DIR}/../raw/build-raw.sh"

log() { echo "[disk-image-arm64-uefi] $*"; }

# Step 1: produce the GPT-layout raw image via the existing builder.
log "delegating to raw builder for GPT layout"
SIZE_GB="${SIZE_GB}" bash "$RAW_BUILDER" --arch "$ARCH" --output "$OUTPUT" --size-gb "$SIZE_GB"

# Step 2: layer identity.cfg + ca.pem onto the EFI partition (P1 in the
# raw layout). Skip if losetup unavailable — the raw builder will have
# already emitted a placeholder image in that case.
if ! command -v losetup >/dev/null 2>&1 || [[ ! -w /dev/loop-control ]]; then
  log "losetup unavailable — skipping identity payload (placeholder image)"
  exit 0
fi
if [[ ! -s "$OUTPUT" ]] || head -c 64 "$OUTPUT" | grep -q "powernode-raw-placeholder"; then
  log "raw builder produced placeholder — skipping identity payload"
  exit 0
fi

LOOP="$(losetup --partscan --find --show "$OUTPUT")"
trap 'umount "${LOOP}p1" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true' EXIT

MNT="$(mktemp -d)"
mount "${LOOP}p1" "$MNT"

# Path C identity placeholder. Same format as RPi 4 build — agent's
# BootIdentityStrategy reads this from whatever path init-powernode.sh
# mounted /boot to (typically /dev/sda1 or /dev/nvme0n1p1 here).
cat >"$MNT/identity.cfg" <<EOF
# Powernode device identity — Path C placeholder
# Agent will fill in ID + KEY via the claim flow on first boot.
ID=
KEY=
SERVER=${PLATFORM_URL}
CA_PEM_FILE=/boot/powernode-ca.pem
EOF

if [[ -n "$CA_PEM_FILE" && -f "$CA_PEM_FILE" ]]; then
  log "embedding platform CA from $CA_PEM_FILE"
  cp "$CA_PEM_FILE" "$MNT/powernode-ca.pem"
else
  log "WARN: --ca-pem-file unset — image will fail TLS verify against platform"
  cat >"$MNT/powernode-ca.pem" <<EOF
# CA placeholder — replace with the platform's CA chain at deploy time.
EOF
fi

# Forward-compat marker for fleet introspection — the agent can sniff
# this to detect that it's running off a claim-flow image vs a per-instance
# baked one.
cat >"$MNT/POWERNODE_CLAIM_FLOW" <<EOF
disk-image-arm64-uefi
built_at=$(date -Iseconds)
platform_url=${PLATFORM_URL}
EOF

umount "$MNT"
rmdir "$MNT"

log "image ready: $OUTPUT"
log "  to flash: sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress conv=fsync"
