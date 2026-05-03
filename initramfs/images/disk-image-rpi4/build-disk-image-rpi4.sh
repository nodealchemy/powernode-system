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
if ! command -v sfdisk >/dev/null 2>&1; then
  log "WARN: sfdisk not installed — emitting placeholder image"
  cat >"$OUTPUT" <<EOF
powernode-disk-image-rpi4-placeholder
size_gb=${SIZE_GB}
platform_url=${PLATFORM_URL}
firmware_dir=${FIRMWARE_DIR:-<unset>}
kernel_initrd_dir=${KERNEL_INITRD_DIR}
EOF
  exit 0
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

# Filesystem creation requires loop device — skip in placeholder mode if
# loopback is unavailable (most CI runners need privileged mode).
if ! command -v losetup >/dev/null 2>&1 || [[ ! -w /dev/loop-control ]]; then
  log "losetup unavailable — skipping FS creation (CI must run privileged for full build)"
  exit 0
fi

LOOP="$(losetup --partscan --find --show "$OUTPUT")"
trap 'umount "${LOOP}p1" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true' EXIT

# FAT32 with the "BOOT" label — init-powernode.sh's mount loop tries
# LABEL=BOOT as one of its fallbacks.
mkfs.fat -F32 -n BOOT "${LOOP}p1"
mkfs.ext4 -F -L persist "${LOOP}p2"

# Mount P1 and stage RPi-bootable contents.
MNT="$(mktemp -d)"
mount "${LOOP}p1" "$MNT"

# RPi GPU firmware (start4.elf, fixup4.dat, bootcode.bin, dtbs).
if [[ -n "$FIRMWARE_DIR" && -d "$FIRMWARE_DIR" ]]; then
  log "copying RPi firmware from $FIRMWARE_DIR"
  cp -a "${FIRMWARE_DIR}/." "$MNT/"
else
  log "WARN: --firmware-dir unset — image will not boot until firmware is layered in"
  cat >"$MNT/FIRMWARE_MISSING.txt" <<EOF
This image lacks RPi GPU firmware. The Pi 4 needs:
  start4.elf, fixup4.dat, bootcode.bin, bcm2711-rpi-4-b.dtb, overlays/

Source: https://github.com/raspberrypi/firmware/tree/master/boot
Or use the powernode rpi4-firmware module which packages these for OCI distribution.
EOF
fi

# Kernel (renamed kernel8.img — RPi 64-bit convention) + initramfs.
if [[ -f "${KERNEL_INITRD_DIR}/kernel" ]]; then
  log "embedding kernel from ${KERNEL_INITRD_DIR}/kernel as /kernel8.img"
  cp "${KERNEL_INITRD_DIR}/kernel" "$MNT/kernel8.img"
else
  log "WARN: kernel missing at ${KERNEL_INITRD_DIR}/kernel — embedding placeholder"
  echo "kernel-placeholder" >"$MNT/kernel8.img"
fi
if [[ -f "${KERNEL_INITRD_DIR}/initramfs.cpio.zst" ]]; then
  log "embedding initramfs from ${KERNEL_INITRD_DIR}/initramfs.cpio.zst"
  cp "${KERNEL_INITRD_DIR}/initramfs.cpio.zst" "$MNT/initramfs.cpio.zst"
else
  log "WARN: initramfs missing at ${KERNEL_INITRD_DIR}/initramfs.cpio.zst — embedding placeholder"
  echo "initramfs-placeholder" >"$MNT/initramfs.cpio.zst"
fi

# RPi GPU bootloader config. arm_64bit=1 selects the 64-bit kernel path.
# enable_uart=1 + dtoverlay=disable-bt frees the PL011 UART for serial console
# (the Pi 4's BT chip is on the mini-UART by default; swap so console works).
# initramfs <name> followkernel tells the GPU bootloader to load the
# initramfs file at the same physical address the kernel expects.
cat >"$MNT/config.txt" <<'CONFIG_TXT'
# Powernode Pi 4 boot configuration
arm_64bit=1
enable_uart=1
dtoverlay=disable-bt
kernel=kernel8.img
initramfs initramfs.cpio.zst followkernel
CONFIG_TXT

# Kernel cmdline. console=serial0 (UART, mapped to PL011 by config.txt
# overlay above) + console=tty1 (HDMI) gives both routes.
# powernode.boot=1 triggers the powernode dracut hook (init-powernode.sh).
# root= points at the persist partition; the agent pivots into a
# composefs-mounted union root after enrollment.
cat >"$MNT/cmdline.txt" <<CMDLINE
console=serial0,115200 console=tty1 powernode.boot=1 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait
CMDLINE

# Path C identity placeholder. Empty ID + KEY signals to BootIdentityStrategy
# that the device hasn't been bound yet — ClaimStrategy will poll
# /node_api/claim until an operator confirms in the UI.
cat >"$MNT/identity.cfg" <<EOF
# Powernode device identity — Path C placeholder
# Agent will fill in ID + KEY via the claim flow on first boot.
ID=
KEY=
SERVER=${PLATFORM_URL}
CA_PEM_FILE=/boot/powernode-ca.pem
EOF

# Platform CA chain. Without this the agent can't verify the platform's
# TLS cert when calling /node_api/claim or /node_api/enroll.
if [[ -n "$CA_PEM_FILE" && -f "$CA_PEM_FILE" ]]; then
  log "embedding platform CA from $CA_PEM_FILE"
  cp "$CA_PEM_FILE" "$MNT/powernode-ca.pem"
else
  log "WARN: --ca-pem-file unset — image will fail TLS verify against platform"
  cat >"$MNT/powernode-ca.pem" <<EOF
# CA placeholder — replace with the platform's CA chain at deploy time.
# In CI this is rendered from the System::InternalCaService output.
EOF
fi

umount "$MNT"
rmdir "$MNT"

log "image ready: $OUTPUT"
log "  to flash: sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress conv=fsync"
