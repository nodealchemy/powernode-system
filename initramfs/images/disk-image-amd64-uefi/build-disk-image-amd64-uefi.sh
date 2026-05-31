#!/usr/bin/env bash
# Builds a generic amd64 UEFI-bootable disk image (.img) for the claim-by-ID
# fleet flow. Operator dd's this onto SD/USB/NVMe, drops a per-instance
# identity.cfg onto the BOOT partition, installs the device, and it claims by
# ID and auto-enrolls. One generic image serves the whole fleet.
#
# Plan: docs/runbooks/fleet-imaging-claim-by-id.md.
#
# Boot model — UKI (Unified Kernel Image): systemd's `ukify` fuses the
# kernel + initramfs + cmdline into ONE EFI binary placed at the ESP's default
# removable-media path /EFI/BOOT/BOOTX64.EFI. OVMF/UEFI firmware boots it with
# zero config (no GRUB, no loader entries). The initramfs boots multi-user.target
# and `boot.mount` mounts the BOOT-labelled ESP at /boot, where the agent's
# BootIdentityStrategy reads identity.cfg and runs the claim flow.
#
# Layout (GPT):
#   p1 — ESP (FAT32, 512 MB, type ef00, FS label BOOT)
#         /EFI/BOOT/BOOTX64.EFI  — the UKI
#         /identity.cfg          — claim placeholder (operator overwrites per device)
#         /powernode-ca.pem      — platform CA chain (private-CA platforms only)
#   p2 — persist (ext4, ~remainder, label persist) — PKI + state survive reboot
#         (critical: claim-by-ID is single-bind, so the enrolled cert MUST
#          persist across reboots or the device can't re-claim)
#
# No-loop assembly (matches build-disk-image.yaml's unprivileged-runner
# contract): ESP via mtools (mformat/mcopy @@offset), persist via
# `mkfs.ext4 -E offset`, GPT via sgdisk. UKI via `ukify` (systemd-ukify) + the
# systemd-boot stub (systemd-boot-efi) + python3-pefile.
set -euo pipefail

# Gitea Actions runners strip sbin paths from non-root PATH; prepend them.
export PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH:-/usr/local/bin:/usr/bin:/bin}"

ARCH="amd64"
OUTPUT=""
SIZE_GB="${SIZE_GB:-8}"
KERNEL_INITRD_DIR="${KERNEL_INITRD_DIR:-}"
PLATFORM_URL="${PLATFORM_URL:-https://platform.example.com}"
CA_PEM_FILE="${CA_PEM_FILE:-}"
# No rd.shell/rd.debug in the generic image — those drop to an emergency shell
# on failure (a security/UX hazard on fielded devices). ttyS0 last = primary
# console, so the agent's output lands on serial for headless debugging while
# tty0 still shows kernel logs on devices with a display.
CMDLINE="${POWERNODE_CMDLINE:-console=tty0 console=ttyS0,115200 powernode.boot=1 ip=dhcp}"
UKIFY="${UKIFY:-ukify}"
EFI_STUB="${EFI_STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --output IMG_PATH [options]

Required:
  --output             Destination .img path

Optional (env vars also accepted):
  --size-gb N          Total image size (default: 8)
  --kernel-initrd-dir DIR  Where to find kernel + initramfs.cpio.zst.
                           Defaults to ../../build/amd64/kernel-initrd
  --platform-url URL   Baked into identity.cfg as SERVER= (default:
                       https://platform.example.com)
  --ca-pem-file PATH   PEM copied to /powernode-ca.pem on the ESP (private CAs).
  --help

Env: UKIFY (ukify command, default 'ukify'), EFI_STUB (systemd-boot stub path),
     POWERNODE_CMDLINE (kernel cmdline baked into the UKI).
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)            OUTPUT="$2"; shift 2 ;;
    --size-gb)           SIZE_GB="$2"; shift 2 ;;
    --kernel-initrd-dir) KERNEL_INITRD_DIR="$2"; shift 2 ;;
    --platform-url)      PLATFORM_URL="$2"; shift 2 ;;
    --ca-pem-file)       CA_PEM_FILE="$2"; shift 2 ;;
    --help|-h)           usage 0 ;;
    *)                   echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -z "$OUTPUT" ]] && usage 1
mkdir -p "$(dirname "$OUTPUT")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_INITRD_DIR="${KERNEL_INITRD_DIR:-${SCRIPT_DIR}/../../build/${ARCH}/kernel-initrd}"

log() { echo "[disk-image-amd64-uefi] $*"; }

KERNEL="${KERNEL_INITRD_DIR}/kernel"
INITRD="${KERNEL_INITRD_DIR}/initramfs.cpio.zst"
for f in "$KERNEL" "$INITRD"; do
  if [[ ! -f "$f" || "$(stat -c%s "$f" 2>/dev/null || echo 0)" -lt 1024 ]]; then
    log "ERROR: missing/empty $f — build the kernel-initrd variant first"
    exit 1
  fi
done

# Required tooling — fail loud (silent placeholders masked real CI breakage).
command -v sgdisk  >/dev/null || { log "ERROR: sgdisk not installed (gdisk pkg)"; exit 1; }
command -v mformat >/dev/null || { log "ERROR: mtools not installed (mtools pkg)"; exit 1; }
"${UKIFY%% *}" --version >/dev/null 2>&1 || command -v "${UKIFY%% *}" >/dev/null 2>&1 \
  || { log "ERROR: ukify not runnable ('$UKIFY') — install systemd-ukify + python3-pefile"; exit 1; }
[[ -f "$EFI_STUB" ]] || { log "ERROR: systemd-boot stub missing ($EFI_STUB) — install systemd-boot-efi"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ── 1. Build the UKI ───────────────────────────────────────────────────────
UKI="$STAGE/BOOTX64.EFI"
log "building UKI (kernel + initramfs + cmdline) via ukify"
# shellcheck disable=SC2086 # $UKIFY may be "python3 /path/ukify" for local runs
$UKIFY build \
  --linux="$KERNEL" \
  --initrd="$INITRD" \
  --cmdline="$CMDLINE" \
  --stub="$EFI_STUB" \
  --output="$UKI"
[[ -s "$UKI" ]] || { log "ERROR: ukify produced no output"; exit 1; }
log "UKI ✓ $(stat -c%s "$UKI") bytes"

# ── 2. identity.cfg placeholder + optional CA ──────────────────────────────
cat >"$STAGE/identity.cfg" <<EOF
# Powernode claim-by-ID identity — PLACEHOLDER.
# Overwrite this per device before installing: download the boot config from
# the target NodeInstance (Download boot config) and copy it here as
# /boot/identity.cfg. SERVER + ID drive claim-by-ID auto-enroll; no secret.
ID=
KEY=
SERVER=${PLATFORM_URL}
# Private-CA platforms: ship the CA as /boot/powernode-ca.pem and uncomment:
# CA_PEM_FILE=/boot/powernode-ca.pem
EOF
if [[ -n "$CA_PEM_FILE" && -f "$CA_PEM_FILE" ]]; then
  cp "$CA_PEM_FILE" "$STAGE/powernode-ca.pem"
  log "embedded platform CA from $CA_PEM_FILE"
fi

# ── 3. GPT disk (ESP + persist) ────────────────────────────────────────────
log "allocating ${SIZE_GB}G image + GPT (ESP[BOOT] + persist)"
truncate -s "${SIZE_GB}G" "$OUTPUT"
sgdisk --zap-all "$OUTPUT" >/dev/null
sgdisk \
  --new=1:0:+512M --typecode=1:ef00 --change-name=1:BOOT \
  --new=2:0:0     --typecode=2:8300 --change-name=2:persist \
  "$OUTPUT" >/dev/null

P1_START=$(sgdisk -i 1 "$OUTPUT" | sed -nE 's/^First sector: ([0-9]+).*/\1/p')
P2_START=$(sgdisk -i 2 "$OUTPUT" | sed -nE 's/^First sector: ([0-9]+).*/\1/p')
P2_END=$(sgdisk   -i 2 "$OUTPUT" | sed -nE 's/^Last sector: ([0-9]+).*/\1/p')
for v in P1_START P2_START P2_END; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { log "ERROR: failed to parse $v from sgdisk -i"; sgdisk -p "$OUTPUT" >&2; exit 1; }
done
P1_OFFSET=$((P1_START * 512))
P2_OFFSET=$((P2_START * 512))
P2_BYTES=$(( (P2_END - P2_START + 1) * 512 ))
log "  p1 ESP:     offset=$P1_OFFSET"
log "  p2 persist: offset=$P2_OFFSET size=$P2_BYTES"

# ── 4. ESP via mtools (FS label BOOT — boot.mount mounts LABEL=BOOT) ────────
log "formatting ESP (FAT32, label BOOT) + staging UKI/identity.cfg/CA"
mformat -F -i "${OUTPUT}@@${P1_OFFSET}" -v BOOT ::
mmd -i "${OUTPUT}@@${P1_OFFSET}" ::/EFI ::/EFI/BOOT
mcopy -i "${OUTPUT}@@${P1_OFFSET}" -Q "$UKI" ::/EFI/BOOT/BOOTX64.EFI
( cd "$STAGE" && for f in identity.cfg powernode-ca.pem; do
    [[ -f "$f" ]] && mcopy -i "${OUTPUT}@@${P1_OFFSET}" -p -Q "$f" "::" || true
  done )

# ── 5. persist via mkfs.ext4 -E offset (no loop) ───────────────────────────
log "formatting persist (ext4, label persist) at offset $P2_OFFSET"
if mkfs.ext4 -F -L persist -b 4096 -E "offset=$P2_OFFSET" "$OUTPUT" "$((P2_BYTES / 4096))" >/dev/null 2>&1; then
  log "persist ✓"
else
  log "WARN: mkfs.ext4 -E offset failed (older e2fsprogs?) — PKI won't survive reboot"
fi

log "image ready: $OUTPUT"
log "  OVMF boots /EFI/BOOT/BOOTX64.EFI (UKI); initramfs mounts LABEL=BOOT at /boot for identity.cfg"
log "  flash: sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress conv=fsync"
