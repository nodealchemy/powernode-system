#!/usr/bin/env bash
# Powernode early-boot hook. Runs from dracut's pre-mount phase.
#
# Responsibilities:
#   1. Verify the agent is staged at /sbin/powernode-agent (and is fs-verity sealed
#      where the kernel supports it).
#   2. Hand off to `powernode-agent boot`, which orchestrates the entire first-boot
#      flow: identity discovery → enrollment → OCI module pull → cosign verify
#      → composefs mount → switch_root.
#   3. If the agent cannot complete (network down, enrollment denied, etc.),
#      drop into the dracut emergency shell with a helpful banner instead of
#      panic'ing the kernel — the operator can recover via console.
#
# Reference: Golden Eclipse plan M3.

# shellcheck disable=SC2034  # 'type' may be referenced by sourcing dracut module
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

powernode_log() {
    echo "[powernode-init] $*" >/dev/kmsg 2>/dev/null || echo "[powernode-init] $*"
}

powernode_emergency() {
    powernode_log "ERROR: $*"
    powernode_log "Dropping to dracut emergency shell. Powernode boot diagnostics:"
    powernode_log "  agent binary: $([[ -x /sbin/powernode-agent ]] && echo present || echo MISSING)"
    powernode_log "  kernel cmdline: $(cat /proc/cmdline)"
    powernode_log "  network: $(ip -br addr 2>/dev/null | head -3)"
    emergency_shell -n powernode "Powernode boot failed: $*"
}

# Sanity: agent must be present.
if [[ ! -x /sbin/powernode-agent ]]; then
    powernode_emergency "powernode-agent missing at /sbin/powernode-agent"
fi

# Honor the powernode.boot=1 cmdline switch — the dracut config bakes this
# in so the hook is always active. Operators can disable via
# `powernode.boot=0` on a recovery boot to skip enrollment + mount.
if ! getarg powernode.boot=1 >/dev/null 2>&1; then
    powernode_log "powernode.boot=0 — skipping agent boot flow (recovery mode?)"
    return 0
fi

# Mount the boot partition before invoking the agent. This is the
# physical-device claim flow's identity source: the FAT32 boot
# partition contains identity.cfg + powernode-ca.pem, which
# BootIdentityStrategy reads to get the platform URL + CA chain
# (plan: docs/plans/wondrous-yawning-anchor.md §4).
#
# Tried in order — first hit wins:
#   1. /dev/mmcblk0p1 — RPi 4 SD card boot partition (FAT32, MBR P1)
#   2. /dev/sda1      — generic UEFI ESP on SATA/USB
#   3. /dev/nvme0n1p1 — generic UEFI ESP on NVMe (Pi 5 NVMe HAT, etc.)
#   4. LABEL=BOOT     — label-based fallback (works after labelling)
#
# Mounted read-only — the agent only reads identity.cfg + ca.pem.
# Failures are non-fatal: VMs and cloud nodes have no boot partition
# and rely on virtio-fw-cfg / cmdline / cloud metadata strategies
# instead. The agent's resolver chain falls through ClaimStrategy →
# cloud strategies when /boot/identity.cfg is absent.
powernode_mount_boot() {
    [[ -d /boot ]] || mkdir -p /boot
    if mountpoint -q /boot 2>/dev/null; then
        powernode_log "  /boot already mounted — skipping"
        return 0
    fi
    for src in /dev/mmcblk0p1 /dev/sda1 /dev/nvme0n1p1 LABEL=BOOT; do
        if mount -o ro "$src" /boot 2>/dev/null; then
            powernode_log "  mounted $src → /boot (ro)"
            return 0
        fi
    done
    powernode_log "  no boot partition found — agent will use other identity strategies"
    return 0
}

powernode_log "Mounting boot partition (claim-flow identity source)…"
powernode_mount_boot

powernode_log "Handing off to powernode-agent boot…"
if ! /sbin/powernode-agent boot; then
    powernode_emergency "powernode-agent boot failed (exit $?)"
fi

powernode_log "powernode-agent boot returned successfully — overlayfs/composefs prepared"
