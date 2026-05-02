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

powernode_log "Handing off to powernode-agent boot…"
if ! /sbin/powernode-agent boot; then
    powernode_emergency "powernode-agent boot failed (exit $?)"
fi

powernode_log "powernode-agent boot returned successfully — overlayfs/composefs prepared"
