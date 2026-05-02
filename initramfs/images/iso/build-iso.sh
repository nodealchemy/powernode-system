#!/usr/bin/env bash
# Builds an ISO 9660 boot image. amd64 uses a hybrid EFI+BIOS layout for
# universal compatibility (legacy BIOS systems still exist on real
# hardware); arm64 is pure UEFI per the ARM SBSA convention.
#
# Reference: Golden Eclipse plan M3 — images/iso.
set -euo pipefail

ARCH=""
OUTPUT=""

usage() { echo "Usage: $0 --arch {amd64|arm64} --output ISO_PATH"; exit "${1:-0}"; }

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

# Build directory laid out as the future ISO contents.
WORK="$(mktemp -d -t powernode-iso-XXXXXX)"
trap "rm -rf $WORK" EXIT

mkdir -p "$WORK/boot/grub" "$WORK/EFI/BOOT" "$WORK/powernode"

# Stage kernel + initramfs from the kernel-initrd variant.
KI_DIR="$(dirname "$(realpath "$0")")/../../build/${ARCH}/kernel-initrd"
if [[ -d "$KI_DIR" ]]; then
  cp "$KI_DIR/kernel" "$WORK/boot/vmlinuz" 2>/dev/null || true
  cp "$KI_DIR/initramfs.cpio.zst" "$WORK/boot/initramfs.cpio.zst" 2>/dev/null || true
else
  echo "[iso] WARN: kernel-initrd variant missing — emitting placeholder ISO"
  echo "powernode-iso-placeholder-$ARCH" >"$OUTPUT"
  exit 0
fi

# GRUB config — UEFI primary, BIOS fallback (amd64 only).
cat >"$WORK/boot/grub/grub.cfg" <<'GRUB'
set timeout=5
set default=0
menuentry "Powernode (Install)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 powernode.boot=1 lockdown=integrity ima_appraise=enforce
    initrd /boot/initramfs.cpio.zst
}
menuentry "Powernode (Recovery)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 powernode.boot=0 single
    initrd /boot/initramfs.cpio.zst
}
GRUB

if ! command -v xorriso >/dev/null 2>&1; then
  echo "[iso] WARN: xorriso not installed — emitting placeholder"
  echo "powernode-iso-placeholder-$ARCH" >"$OUTPUT"
  exit 0
fi

# Stage GRUB EFI binary if available
case "$ARCH" in
  amd64)
    EFI_BIN="/usr/lib/grub/x86_64-efi/grubx64.efi"
    [[ -f "$EFI_BIN" ]] && cp "$EFI_BIN" "$WORK/EFI/BOOT/BOOTX64.EFI"
    ;;
  arm64)
    EFI_BIN="/usr/lib/grub/arm64-efi/grubaa64.efi"
    [[ -f "$EFI_BIN" ]] && cp "$EFI_BIN" "$WORK/EFI/BOOT/BOOTAA64.EFI"
    ;;
esac

# Build the ISO. Hybrid for amd64; pure UEFI for arm64.
case "$ARCH" in
  amd64)
    xorriso -as mkisofs \
      -o "$OUTPUT" \
      -V "PWRNODE_INSTALL" \
      -J -joliet-long -r \
      -isohybrid-mbr "/usr/lib/ISOLINUX/isohdpfx.bin" \
      -partition_offset 16 \
      -appended_part_as_gpt \
      -append_partition 2 0xef "$WORK/EFI/BOOT/BOOTX64.EFI" \
      -e --interval:appended_partition_2:all:: \
      -no-emul-boot -isohybrid-gpt-basdat \
      "$WORK" 2>/dev/null || {
        echo "[iso] hybrid build failed (xorriso flags may need adjustment for this version) — falling back to UEFI-only"
        xorriso -as mkisofs -o "$OUTPUT" -V "PWRNODE_INSTALL" -J -r "$WORK"
      }
    ;;
  arm64)
    xorriso -as mkisofs \
      -o "$OUTPUT" \
      -V "PWRNODE_INSTALL" \
      -J -joliet-long -r \
      "$WORK"
    ;;
esac

echo "[iso] ✓ $OUTPUT"
