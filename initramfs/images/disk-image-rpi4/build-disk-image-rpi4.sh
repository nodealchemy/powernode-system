#!/usr/bin/env bash
# Builds a Raspberry Pi 4-bootable disk image (.img) for the physical-device
# claim flow. Operator dd's this onto an SD card, plugs the Pi in, and the
# device polls /node_api/claim until an operator confirms in the UI.
#
# Plan: docs/plans/wondrous-yawning-anchor.md §3 (build pipeline) + §4 (claim flow).
#
# Why MBR (not GPT): the Pi 4's GPU bootloader (start4.elf, baked into the
# Broadcom SoC ROM) reads partition 1 from MBR-formatted media only — it
# cannot parse GPT. Generic UEFI hardware (build-disk-image-arm64-uefi.sh)
# uses GPT and wraps build-raw.sh; this script is RPi-specific.
#
# Layout:
#   p1 — boot (FAT32, 512 MB, MBR primary, bootable flag)
#         /start4.elf, /fixup4.dat, /bcm2711-rpi-4-b.dtb, /overlays/
#         /kernel8.img         — renamed from arm64 vmlinuz (RPi 64-bit name)
#         /initramfs.cpio.zst
#         /cmdline.txt         — kernel cmdline (powernode.boot=1 …)
#         /config.txt          — RPi GPU bootloader config
#         /identity.cfg        — Path C placeholder (ID=, KEY=, SERVER=, CA_PEM_FILE=)
#         /powernode-ca.pem    — platform CA chain (baked at build time)
#   p2 — persist (ext4, ~remainder) — /persist/var bind target
#
# Required binaries: sgdisk-equivalent (parted or fdisk), mkfs.fat, mkfs.ext4.
# RPi firmware files (start4.elf etc.) sourced from the rpi4-firmware module —
# this script accepts a --firmware-dir flag pointing at the unpacked module.
set -euo pipefail

# Ensure standard sbin paths are searchable. Gitea Actions runners commonly
# strip /usr/sbin and /sbin from non-root user PATH, hiding sfdisk, losetup,
# mkfs.fat, mkfs.ext4 — all of which we need. Prepending unconditionally is
# safe (idempotent) and matches the behavior of every distro's interactive
# root shell.
export PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH:-/usr/local/bin:/usr/bin:/bin}"

ARCH="arm64"           # RPi 4 is arm64-only (32-bit Pi support deferred)
OUTPUT=""
SIZE_GB="${SIZE_GB:-4}"
FIRMWARE_DIR="${FIRMWARE_DIR:-}"
KERNEL_INITRD_DIR="${KERNEL_INITRD_DIR:-}"
PLATFORM_URL="${PLATFORM_URL:-https://platform.example.com}"
CA_PEM_FILE="${CA_PEM_FILE:-}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --output IMG_PATH [options]

Required:
  --output             Destination .img path

Optional (env vars also accepted):
  --size-gb N          Total image size (default: 4)
  --firmware-dir DIR   Path to rpi4-firmware module rootfs (start4.elf etc.).
                       If unset, emits a placeholder noting missing firmware.
  --kernel-initrd-dir DIR  Where to find kernel + initramfs.cpio.zst.
                           Defaults to ../../build/arm64/kernel-initrd
  --platform-url URL   Baked into identity.cfg as SERVER= (default:
                       https://platform.example.com)
  --ca-pem-file PATH   PEM file copied to /powernode-ca.pem on boot partition.
                       If unset, embeds a placeholder note.
  --help

Notes:
  - Requires root or losetup access for filesystem creation.
  - In CI without losetup (unprivileged runner), emits a placeholder image
    listing the layout it WOULD have created — useful for build-pipeline
    smoke tests without privileged execution.
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)            OUTPUT="$2"; shift 2 ;;
    --size-gb)           SIZE_GB="$2"; shift 2 ;;
    --firmware-dir)      FIRMWARE_DIR="$2"; shift 2 ;;
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

log() { echo "[disk-image-rpi4] $*"; }

log "allocating ${SIZE_GB}G sparse image at $OUTPUT"
truncate -s "${SIZE_GB}G" "$OUTPUT"

# MBR via sfdisk: more scriptable than fdisk and ubiquitous. parted's MBR
# support exists but its scripting interface is fragile.
# **Fail hard** if sfdisk is missing — silent placeholder emission was
# masking real CI failures (a 238-byte placeholder file was getting pushed
# to OCI + ingested by the platform as if it were a valid disk image).
# If you want a placeholder for tests, use --output-mode=placeholder (TODO).
if ! command -v sfdisk >/dev/null 2>&1; then
  log "ERROR: sfdisk not installed (PATH=$PATH)"
  log "ERROR: install util-linux (Debian/Ubuntu) or fdisk (split package on newer distros)"
  log "ERROR: refusing to emit placeholder image — that masks the real issue"
  exit 1
fi

# MBR layout: P1 = 512MB FAT32 boot (bootable), P2 = remainder ext4 persist.
# The "0c" type code is "W95 FAT32 (LBA)" — the only one the RPi GPU
# bootloader recognizes. P2 is "83" = Linux native.
sfdisk "$OUTPUT" <<SFDISK_EOF >/dev/null
label: dos
unit: sectors
,1048576,c,*
,,83
SFDISK_EOF

log "partition table:"
sfdisk -d "$OUTPUT" | tail -3

# Compute partition byte offsets from the sfdisk dump. sfdisk's output
# format is whitespace-padded (`start=        2048,`), so awk field
# splitting gets ugly — sed regex is more robust.
DUMP=$(sfdisk -d "$OUTPUT")
P1_LINE=$(echo "$DUMP" | grep -E 'type=c[, ]')
P2_LINE=$(echo "$DUMP" | grep -E 'type=83[, ]?')
P1_START_SECTORS=$(echo "$P1_LINE" | sed -E 's/.*start=[[:space:]]*([0-9]+).*/\1/')
P1_SIZE_SECTORS=$( echo "$P1_LINE" | sed -E 's/.*size=[[:space:]]*([0-9]+).*/\1/')
P2_START_SECTORS=$(echo "$P2_LINE" | sed -E 's/.*start=[[:space:]]*([0-9]+).*/\1/')
P2_SIZE_SECTORS=$( echo "$P2_LINE" | sed -E 's/.*size=[[:space:]]*([0-9]+).*/\1/')

# Sanity-check the parses — if anything is empty or non-numeric we'd corrupt
# the partition offsets and silently produce a broken image.
for v in P1_START_SECTORS P1_SIZE_SECTORS P2_START_SECTORS P2_SIZE_SECTORS; do
  if ! [[ "${!v}" =~ ^[0-9]+$ ]]; then
    log "ERROR: failed to parse $v from sfdisk dump:"
    echo "$DUMP" >&2
    exit 1
  fi
done
P1_OFFSET=$((P1_START_SECTORS * 512))
P2_OFFSET=$((P2_START_SECTORS * 512))
P1_BYTES=$((P1_SIZE_SECTORS  * 512))
P2_BYTES=$((P2_SIZE_SECTORS  * 512))
log "  p1 (FAT32 boot): offset=$P1_OFFSET size=$P1_BYTES"
log "  p2 (ext4 persist): offset=$P2_OFFSET size=$P2_BYTES"

# Stage all FAT32-boot contents into a temp dir. Both the offline (mtools)
# and losetup paths copy from this directory.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# RPi GPU firmware (start4.elf, fixup4.dat, bootcode.bin, dtbs, kernel8.img).
if [[ -n "$FIRMWARE_DIR" && -d "$FIRMWARE_DIR" ]]; then
  log "staging RPi firmware from $FIRMWARE_DIR"
  cp -a "${FIRMWARE_DIR}/." "$STAGE/"
else
  log "WARN: --firmware-dir unset — image will not boot until firmware is layered in"
  cat >"$STAGE/FIRMWARE_MISSING.txt" <<EOF
This image lacks RPi GPU firmware. The Pi 4 needs:
  start4.elf, fixup4.dat, bootcode.bin, bcm2711-rpi-4-b.dtb, overlays/, kernel8.img

Source: https://github.com/raspberrypi/firmware/tree/master/boot
Or use the powernode rpi4-firmware module which packages these for OCI distribution.
EOF
fi

# Kernel — prefer locally-built (KERNEL_INITRD_DIR/kernel from dracut) if
# present, else fall back to the firmware-distributed kernel8.img (already
# in $STAGE/ from the firmware copy above), else placeholder. The
# firmware-distributed kernel boots far enough to print on serial console
# even without our dracut-built initramfs, which is enough for an SD-card
# flash test.
if [[ -f "${KERNEL_INITRD_DIR}/kernel" ]] && [[ "$(stat -c '%s' "${KERNEL_INITRD_DIR}/kernel")" -gt 1024 ]]; then
  log "staging custom kernel from ${KERNEL_INITRD_DIR}/kernel as kernel8.img"
  cp "${KERNEL_INITRD_DIR}/kernel" "$STAGE/kernel8.img"
elif [[ -f "$STAGE/kernel8.img" ]] && [[ "$(stat -c '%s' "$STAGE/kernel8.img")" -gt 1024 ]]; then
  log "using firmware-distributed kernel8.img ($(stat -c '%s' "$STAGE/kernel8.img") bytes)"
else
  log "WARN: no kernel available — embedding placeholder"
  echo "kernel-placeholder" >"$STAGE/kernel8.img"
fi
if [[ -f "${KERNEL_INITRD_DIR}/initramfs.cpio.zst" ]] && [[ "$(stat -c '%s' "${KERNEL_INITRD_DIR}/initramfs.cpio.zst")" -gt 1024 ]]; then
  log "staging initramfs from ${KERNEL_INITRD_DIR}/initramfs.cpio.zst"
  cp "${KERNEL_INITRD_DIR}/initramfs.cpio.zst" "$STAGE/initramfs.cpio.zst"
else
  log "WARN: initramfs missing — embedding placeholder"
  echo "initramfs-placeholder" >"$STAGE/initramfs.cpio.zst"
fi

cat >"$STAGE/config.txt" <<'CONFIG_TXT'
# Powernode Pi 4 boot configuration
arm_64bit=1
enable_uart=1
dtoverlay=disable-bt
kernel=kernel8.img
initramfs initramfs.cpio.zst followkernel
CONFIG_TXT

cat >"$STAGE/cmdline.txt" <<CMDLINE
console=serial0,115200 console=tty1 powernode.boot=1 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait
CMDLINE

cat >"$STAGE/identity.cfg" <<EOF
# Powernode device identity — Path C placeholder
# Agent will fill in ID + KEY via the claim flow on first boot.
ID=
KEY=
SERVER=${PLATFORM_URL}
CA_PEM_FILE=/boot/powernode-ca.pem
EOF

if [[ -n "$CA_PEM_FILE" && -f "$CA_PEM_FILE" ]]; then
  log "staging platform CA from $CA_PEM_FILE"
  cp "$CA_PEM_FILE" "$STAGE/powernode-ca.pem"
else
  log "WARN: --ca-pem-file unset — image will fail TLS verify against platform"
  cat >"$STAGE/powernode-ca.pem" <<EOF
# CA placeholder — replace with the platform's CA chain at deploy time.
# In CI this is rendered from the System::InternalCaService output.
EOF
fi

# ── Filesystem creation: try offline first (no losetup), fall back to
#    losetup on privileged runners, fall back to placeholder on neither.
HAVE_MTOOLS=0
if command -v mformat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
  HAVE_MTOOLS=1
fi
HAVE_LOSETUP=0
if command -v losetup >/dev/null 2>&1 && [[ -w /dev/loop-control ]]; then
  HAVE_LOSETUP=1
fi

if [[ "$HAVE_MTOOLS" -eq 1 ]]; then
  log "creating FAT32 boot partition via mtools at offset $P1_OFFSET (offline, no losetup)"
  # mformat -F = FAT32, -i image@@offset = address partition inside disk image,
  # -v BOOT = volume label (init-powernode.sh tries LABEL=BOOT).
  mformat -F -i "${OUTPUT}@@${P1_OFFSET}" -v BOOT ::
  log "populating FAT32 with $(find "$STAGE" -type f | wc -l) files / $(find "$STAGE" -type d | wc -l) dirs"
  ( cd "$STAGE" && for entry in * .* ; do
      [[ "$entry" == "." || "$entry" == ".." ]] && continue
      [[ ! -e "$entry" ]] && continue
      if [[ -d "$entry" ]]; then
        mcopy -i "${OUTPUT}@@${P1_OFFSET}" -s -p -Q "$entry" "::" || log "WARN: mcopy dir $entry failed"
      else
        mcopy -i "${OUTPUT}@@${P1_OFFSET}" -p -Q "$entry" "::" || log "WARN: mcopy $entry failed"
      fi
    done )

  log "creating ext4 persist partition via mkfs.ext4 -E offset=$P2_OFFSET"
  # -b 4096 = 4K blocks; size argument is in blocks. -E offset places the
  # filesystem at the given byte offset within the containing file.
  if mkfs.ext4 -F -L persist -b 4096 -E "offset=$P2_OFFSET" "$OUTPUT" "$((P2_BYTES / 4096))"; then
    log "ext4 persist partition created"
  else
    log "WARN: mkfs.ext4 -E offset failed (older e2fsprogs?) — kernel will hang on rootwait"
  fi
  log "image ready: $OUTPUT (offline-FS mode — bootable to GPU loader stage)"
elif [[ "$HAVE_LOSETUP" -eq 1 ]]; then
  log "mtools unavailable — falling back to losetup-based FS creation (privileged runner)"
  LOOP="$(losetup --partscan --find --show "$OUTPUT")"
  trap 'umount "${LOOP}p1" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; rm -rf "$STAGE"' EXIT
  mkfs.fat -F32 -n BOOT "${LOOP}p1"
  mkfs.ext4 -F -L persist "${LOOP}p2"
  MNT="$(mktemp -d)"
  mount "${LOOP}p1" "$MNT"
  cp -a "$STAGE/." "$MNT/"
  umount "$MNT"
  rmdir "$MNT"
  log "image ready: $OUTPUT (losetup mode)"
else
  log "WARN: neither mtools nor losetup available — exiting with partition table only"
  log "WARN: install mtools (apt install mtools) for offline FS creation"
  exit 0
fi

log "  to flash: sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress conv=fsync"
