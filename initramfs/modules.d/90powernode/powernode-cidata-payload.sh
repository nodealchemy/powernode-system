#!/bin/sh
# Powernode NoCloud federation-payload stager (pre-pivot).
#
# The UKI pivot-boot image (images/disk-image-amd64-uefi/build-disk-image-amd64-uefi.sh)
# has NO cloud-init. But a Proxmox federation spawn under a non-root API token
# can't use fw-cfg (PVE restricts the `args` field to root@pam), so the provider
# delivers the federation payload on a PVE cloud-init NoCloud CD-ROM
# (ide2 => "<storage>:cloudinit,media=cdrom"). The agent's federation-accept
# reads fw-cfg first, then falls back to /etc/powernode/federation-payload.json
# (agent/internal/federation/config.go PayloadFilePath) — but nothing pre-pivot
# writes that file, because there is no cloud-init to process a write_files
# directive. So the child never enrolls.
#
# This oneshot bridges the gap: mount the NoCloud CD-ROM read-only, and if it
# carries a non-empty `user-data`, copy it VERBATIM to the payload path (0600)
# for powernode-federation-accept.service to consume. The provider writes that
# user-data as the RAW spawn_payload JSON (ProxmoxProvider
# #apply_default_federation_user_data, boot_mode: "uefi_disk"), byte-identical
# to what CloudSeed embeds in its federation-payload.json write_files entry — so
# it drops in as the agent's file fallback with no cloud-init and no YAML parse.
#
# Safe no-op (exit 0) whenever there is no NoCloud drive — the steady state for
# local_qemu, direct-kernel, and bare-metal boots that never received a cicustom
# seed. Never errors the boot, never hangs, adds no latency to those boots.

PAYLOAD_DEST="/etc/powernode/federation-payload.json"
MNT="/run/powernode-cidata"

log() { echo "[powernode-cidata] $*"; }

# Fast, latency-free exit when this boot has no NoCloud drive at all. PVE always
# attaches its cloud-init seed as an optical (media=cdrom) device, so the
# absence of both an optical node and a cidata-labelled device means there is
# nothing to stage.
if [ ! -b /dev/sr0 ] && [ ! -b /dev/sr1 ] &&
   [ ! -e /dev/disk/by-label/cidata ] && [ ! -e /dev/disk/by-label/CIDATA ]; then
    log "no NoCloud (cidata) drive present — nothing to stage"
    exit 0
fi

mkdir -p "$MNT"

# Mount the NoCloud CD-ROM read-only. cloud-init's NoCloud datasource locates it
# as TYPE=iso9660 intersected with LABEL=CIDATA / cidata (DataSourceNoCloud.py),
# so the exact label casing is genuinely provider-dependent. Try the raw optical
# nodes first (the only optical device on a Powernode-managed VM, so
# label-independent), then the by-label symlinks for either ISO9660 casing —
# same multi-candidate shape as init-powernode.sh's powernode_mount_boot().
mounted=1
for src in /dev/sr0 /dev/sr1 /dev/disk/by-label/cidata /dev/disk/by-label/CIDATA; do
    [ -e "$src" ] || continue
    if mount -t iso9660 -o ro "$src" "$MNT" 2>/dev/null; then
        log "mounted $src -> $MNT (iso9660, ro)"
        mounted=0
        break
    fi
done

if [ "$mounted" -ne 0 ]; then
    log "cidata device present but not mountable — nothing to stage"
    exit 0
fi

if [ -s "$MNT/user-data" ]; then
    mkdir -p /etc/powernode
    # The payload carries a single-use acceptance_token in cleartext. umask
    # keeps the file from being briefly group/world-readable between create and
    # chmod; cp + chmod pin it at 0600; root ownership is implicit (this oneshot
    # runs as root). Same 0600 rationale as the provider's stage_cicustom
    # snippet write.
    umask 077
    rm -f "$PAYLOAD_DEST"
    if cp "$MNT/user-data" "$PAYLOAD_DEST" && chmod 0600 "$PAYLOAD_DEST"; then
        log "staged federation payload -> $PAYLOAD_DEST (0600)"
    else
        log "WARN: failed to stage user-data -> $PAYLOAD_DEST"
    fi
else
    log "cidata drive has no non-empty user-data — nothing to stage"
fi

umount "$MNT" 2>/dev/null || true
exit 0
