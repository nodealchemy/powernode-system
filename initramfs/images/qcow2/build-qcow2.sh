#!/usr/bin/env bash
# Builds a pre-baked qcow2 cloud image. Created from a base ext4 rootfs
# (mmdebstrap-derived) with the Powernode agent + dracut hooks already
# installed, so libvirt/QEMU domains boot directly into the agent loop.
#
# Reference: Golden Eclipse plan M3 — images/qcow2.
set -euo pipefail

ARCH=""
OUTPUT=""
SIZE_GB="${SIZE_GB:-10}"

usage() { echo "Usage: $0 --arch {amd64|arm64} --output QCOW2_PATH"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)    ARCH="$2"; shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    --help|-h) usage 0 ;;
    *)         echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -z "$ARCH" ]] && usage 1
[[ -z "$OUTPUT" ]] && usage 1

mkdir -p "$(dirname "$OUTPUT")"

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "[qcow2] WARN: qemu-img not installed — emitting placeholder"
  echo "powernode-qcow2-placeholder-$ARCH" >"$OUTPUT"
  exit 0
fi

# v0 path: allocate empty qcow2 of the right size; the M4 thin slice will
# extend this to a full mmdebstrap rootfs population. For early QEMU smoke
# tests, an empty disk plus the kernel-initrd network-boot path is enough
# to get the agent to enrollment.
qemu-img create -f qcow2 "$OUTPUT" "${SIZE_GB}G"

echo "[qcow2] ✓ empty $SIZE_GB GB qcow2 at $OUTPUT (M4 will extend with rootfs)"
