#!/usr/bin/env bash
# Builds a generic arm64 UEFI-bootable disk image (.img) for the claim-by-ID
# fleet flow (Pi 5 / Ampere / generic UEFI arm64). Mirror of the amd64 builder:
# operator dd's this onto SD/USB/NVMe, drops a per-instance identity.cfg onto
# the BOOT partition, installs the device, and it claims by ID and auto-enrolls.
# One generic image serves the whole arm64 UEFI fleet.
#
# Plan: docs/runbooks/fleet-imaging-claim-by-id.md.
#
# Boot model — UKI (Unified Kernel Image): systemd's `ukify` fuses the
# kernel + initramfs + cmdline into ONE EFI binary placed at the ESP's default
# removable-media path /EFI/BOOT/BOOTAA64.EFI (the aarch64 fallback path).
# UEFI firmware boots it with zero config (no GRUB, no loader entries). The
# initramfs boots multi-user.target and `boot.mount` mounts the BOOT-labelled
# ESP at /boot, where the agent's BootIdentityStrategy reads identity.cfg.
#
# This replaces the earlier build-raw.sh delegation (3-partition layout that
# didn't fit the registry blob limit) — the UKI model is identical to amd64,
# compact (2-partition), and consistent across architectures.
#
# Layout (GPT):
#   p1 — ESP (FAT32, 512 MB, type ef00, FS label BOOT)
#         /EFI/BOOT/BOOTAA64.EFI — the UKI
#         /identity.cfg          — claim placeholder (operator overwrites per device)
#         /powernode-ca.pem      — platform CA chain (private-CA platforms only)
#   p2 — persist (ext4, ~remainder, label persist) — PKI + state survive reboot
#
# No-loop assembly (matches build-disk-image.yaml's unprivileged-runner
# contract): ESP via mtools (mformat/mcopy @@offset), persist via
# `mkfs.ext4 -E offset`, GPT via sgdisk. UKI via `ukify` (systemd-ukify) + the
# aarch64 systemd-boot stub (linuxaa64.efi.stub, systemd-boot-efi) + python3-pefile.
set -euo pipefail

# Gitea Actions runners strip sbin paths from non-root PATH; prepend them.
export PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH:-/usr/local/bin:/usr/bin:/bin}"

ARCH="arm64"
OUTPUT=""
SIZE_GB="${SIZE_GB:-8}"
KERNEL_INITRD_DIR="${KERNEL_INITRD_DIR:-}"
PLATFORM_URL="${PLATFORM_URL:-https://platform.example.com}"
CA_PEM_FILE="${CA_PEM_FILE:-}"
# No rd.shell/rd.debug in the generic image — those drop to an emergency shell
# on failure (a security/UX hazard on fielded devices). On ARM the primary
# serial is ttyAMA0 (pl011 — Pi + SBSA servers); ttyS0 covers 8250 UARTs; tty0
# keeps kernel logs on an attached display. Last console = primary (userspace
# stdout) → ttyAMA0 for headless ARM serial debugging.
CMDLINE="${POWERNODE_CMDLINE:-console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 powernode.boot=1 ip=dhcp}"
# Bake the image build git_sha into the kernel cmdline so the on-node agent can
# report the disk image it actually booted from (campaign 019f505f — boot-image
# drift visibility). Only appended when the build knows its sha (CI passes
# POWERNODE_IMAGE_GIT_SHA=<github.sha>); local builds without it omit the marker.
if [[ -n "${POWERNODE_IMAGE_GIT_SHA:-}" ]]; then
    CMDLINE="${CMDLINE} powernode.image_git_sha=${POWERNODE_IMAGE_GIT_SHA}"
fi
UKIFY="${UKIFY:-ukify}"
EFI_STUB="${EFI_STUB:-/usr/lib/systemd/boot/efi/linuxaa64.efi.stub}"
# systemd-boot BOOT MANAGER (campaign 019f505f inc 3) — see amd64 for rationale.
SDBOOT="${SDBOOT:-/usr/lib/systemd/boot/efi/systemd-bootaa64.efi}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --output IMG_PATH [options]

Required:
  --output             Destination .img path

Optional (env vars also accepted):
  --size-gb N          Total image size (default: 8)
  --kernel-initrd-dir DIR  Where to find kernel + initramfs.cpio.zst.
                           Defaults to ../../build/arm64/kernel-initrd
  --platform-url URL   Baked into identity.cfg as SERVER= (default:
                       https://platform.example.com)
  --ca-pem-file PATH   PEM copied to /powernode-ca.pem on the ESP (private CAs).
  --help

Env: UKIFY (ukify command, default 'ukify'), EFI_STUB (systemd-boot stub path,
     default the aarch64 linuxaa64.efi.stub), POWERNODE_CMDLINE (kernel cmdline).
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

log() { echo "[disk-image-arm64-uefi] $*"; }

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
UKI="$STAGE/BOOTAA64.EFI"
log "building UKI (kernel + initramfs + cmdline) via ukify"
# ukify autodetects --uname by scraping the kernel as an ELF; the arm64 vmlinuz
# is an arm64 Image (not ELF), so ukify's scrape_elf raises
# "TypeError: expected str, bytes or os.PathLike object, not NoneType". Supply
# --uname explicitly (the build kernel's version, from its modules dir) to skip
# autodetection. amd64's bzImage scrapes fine, but being explicit is harmless.
UNAME_KVER="${UNAME_KVER:-$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1)}"
[[ -n "$UNAME_KVER" ]] && log "ukify --uname=$UNAME_KVER (skipping ELF autodetect — arm64 kernel isn't ELF)"
# shellcheck disable=SC2086 # $UKIFY may be "python3 /path/ukify"; ${UNAME_KVER:+…} intentionally unquoted
$UKIFY build \
  --linux="$KERNEL" \
  --initrd="$INITRD" \
  --cmdline="$CMDLINE" \
  --stub="$EFI_STUB" \
  ${UNAME_KVER:+--uname "$UNAME_KVER"} \
  --output="$UKI"
[[ -s "$UKI" ]] || { log "ERROR: ukify produced no output"; exit 1; }
log "UKI ✓ $(stat -c%s "$UKI") bytes"

# Export the UKI beside the .img so CI can publish it as a standalone,
# cosign-signed OCI artifact for in-place boot-image upgrades (campaign 019f505f
# inc 2). $STAGE is wiped by the EXIT trap, so copy it out now.
if [[ -n "${OUTPUT:-}" ]]; then
  cp "$UKI" "${OUTPUT%.img}.uki"
  log "exported UKI → ${OUTPUT%.img}.uki"
fi

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
P1_END=$(sgdisk   -i 1 "$OUTPUT" | sed -nE 's/^Last sector: ([0-9]+).*/\1/p')
P2_START=$(sgdisk -i 2 "$OUTPUT" | sed -nE 's/^First sector: ([0-9]+).*/\1/p')
P2_END=$(sgdisk   -i 2 "$OUTPUT" | sed -nE 's/^Last sector: ([0-9]+).*/\1/p')
for v in P1_START P1_END P2_START P2_END; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { log "ERROR: failed to parse $v from sgdisk -i"; sgdisk -p "$OUTPUT" >&2; exit 1; }
done
P1_OFFSET=$((P1_START * 512))
# See the amd64 script: mformat's @@offset conveys the partition START only, so
# left to itself mtools sizes the filesystem from the rest of the image file and
# silently builds a FAT that overruns its own partition.
P1_SECTORS=$(( P1_END - P1_START + 1 ))
P1_BYTES=$(( P1_SECTORS * 512 ))
P2_OFFSET=$((P2_START * 512))
P2_BYTES=$(( (P2_END - P2_START + 1) * 512 ))
log "  p1 ESP:     offset=$P1_OFFSET size=$P1_BYTES ($P1_SECTORS sectors)"
log "  p2 persist: offset=$P2_OFFSET size=$P2_BYTES"

# ── 4. ESP via mtools — systemd-boot manager + boot-counted UKI slot A ──────
# See the amd64 script for the full A/B-rollout rationale (campaign 019f505f
# inc 3). Firmware auto-loads /EFI/BOOT/BOOTAA64.EFI = systemd-boot; UKIs live in
# /EFI/Linux; slot A is the good default.
[[ -f "$SDBOOT" ]] || { log "ERROR: systemd-boot manager missing ($SDBOOT) — install systemd-boot-efi"; exit 1; }
cat >"$STAGE/loader.conf" <<'LOADER'
timeout 3
default powernode-a*
editor  no
LOADER
log "formatting ESP (FAT32, label BOOT) + systemd-boot + UKI slot A"
mformat -F -T "$P1_SECTORS" -i "${OUTPUT}@@${P1_OFFSET}" -v BOOT ::
# Fail the build rather than ship an ESP that overruns its partition. Files still
# read back correctly while the filesystem is merely *capable* of overrunning, so
# only this boot-sector check catches it — a functional smoke test cannot.
ESP_DECLARED=$(od -An -tu2 -j $((P1_OFFSET + 19)) -N2 "$OUTPUT" | tr -d ' ')
if [[ "${ESP_DECLARED:-0}" -eq 0 ]]; then
  ESP_DECLARED=$(od -An -tu4 -j $((P1_OFFSET + 32)) -N4 "$OUTPUT" | tr -d ' ')
fi
if [[ "${ESP_DECLARED:-0}" -le 0 || "${ESP_DECLARED}" -gt "$P1_SECTORS" ]]; then
  log "ERROR: ESP filesystem declares ${ESP_DECLARED} sectors but partition holds only ${P1_SECTORS}"
  exit 1
fi
log "  ESP sanity: filesystem declares ${ESP_DECLARED} sectors ≤ ${P1_SECTORS} partition sectors ✓"
mmd -i "${OUTPUT}@@${P1_OFFSET}" ::/EFI ::/EFI/BOOT ::/EFI/Linux ::/EFI/systemd ::/loader
mcopy -i "${OUTPUT}@@${P1_OFFSET}" -Q "$SDBOOT" ::/EFI/BOOT/BOOTAA64.EFI
mcopy -i "${OUTPUT}@@${P1_OFFSET}" -Q "$SDBOOT" ::/EFI/systemd/systemd-bootaa64.efi
mcopy -i "${OUTPUT}@@${P1_OFFSET}" -Q "$UKI"    ::/EFI/Linux/powernode-a.efi
mcopy -i "${OUTPUT}@@${P1_OFFSET}" -Q "$STAGE/loader.conf" ::/loader/loader.conf
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
log "  UEFI firmware boots /EFI/BOOT/BOOTAA64.EFI (UKI); initramfs mounts LABEL=BOOT at /boot for identity.cfg"
log "  flash: sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress conv=fsync"
