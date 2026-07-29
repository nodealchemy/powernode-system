#!/bin/sh
# Powernode NoCloud cicustom stager (pre-pivot) — federation payload AND
# Option 3 enrollment identity.
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
# The SAME cicustom transport also carries pool-provisioned builder ENROLLMENT
# identity (Option 3 — the fw-cfg-via-args path is blocked for API-token PVE
# connections the same way federation's is): System::Providers::Proxmox::
# EnrollmentSeed#render_cicustom renders a `user-data` that is the sourced-shell
# identity.cfg format (ID=/KEY=/SERVER=/CA_PEM_FILE=) instead of JSON, with
# `meta-data` carrying the raw CA PEM. The two shapes are distinguished by
# content: federation user-data is always a JSON object (starts with `{`);
# enrollment identity.cfg never does. Federation and enrollment are mutually
# exclusive per VM (ProxmoxProvider only renders one cicustom user_data).
#
# This oneshot bridges the gap: mount the NoCloud CD-ROM read-only, and if it
# carries a non-empty `user-data`, route on its shape:
#   - JSON (`{...}`)   → copy VERBATIM to the federation payload path (0600)
#                        for powernode-federation-accept.service to consume.
#                        The provider writes that user-data as the RAW
#                        spawn_payload JSON (ProxmoxProvider
#                        #apply_default_federation_user_data, boot_mode:
#                        "uefi_disk"), byte-identical to what CloudSeed embeds
#                        in its federation-payload.json write_files entry — so
#                        it drops in as the agent's file fallback with no
#                        cloud-init and no YAML parse.
#   - identity.cfg     → copy `user-data` to /run/powernode/identity.cfg (0600)
#                        and `meta-data` (the raw CA PEM) to
#                        /run/powernode/enroll-ca.pem (0644) for the agent's
#                        early LocalIdentityStrategy (agent/internal/identity/
#                        identity.go DefaultResolver) to consume, Before=
#                        powernode-agent.service.
#
# Safe no-op (exit 0) whenever there is no NoCloud drive — the steady state for
# local_qemu, direct-kernel, and bare-metal boots that never received a cicustom
# seed. Never errors the boot, never hangs, adds no latency to those boots.

PAYLOAD_DEST="/etc/powernode/federation-payload.json"
IDENTITY_DEST="/run/powernode/identity.cfg"
ENROLL_CA_DEST="/run/powernode/enroll-ca.pem"
MNT="/run/powernode-cidata"

log() { echo "[powernode-cidata] $*"; }

# PVE always attaches its cloud-init seed as an optical (media=cdrom) device,
# so the absence of both an optical node and a cidata-labelled device means
# there is nothing to stage.
# Candidate list is overridable ONLY so the guard is exercisable on a host
# that has (or lacks) a real optical device; nothing in production sets it.
# Without the seam the enumeration-wait below is untestable except by booting
# a VM, which for a unit that gates node enrollment is a bad place to find out
# it is wrong.
CIDATA_DEVICES="${CIDATA_DEVICES:-/dev/sr0 /dev/sr1 /dev/disk/by-label/cidata /dev/disk/by-label/CIDATA}"

# -e rather than -b: it must match both the raw optical nodes and the
# by-label SYMLINKS. Being permissive is safe — a false positive falls
# through to the mount loop below, which fails cleanly and still exits 0
# ("cidata device present but not mountable").
cidata_device_present() {
    for _d in $CIDATA_DEVICES; do
        if [ -e "$_d" ]; then
            return 0
        fi
    done
    return 1
}

# WAIT FOR ENUMERATION BEFORE CONCLUDING "ABSENT".
#
# This unit is ordered only After=basic.target, which does NOT mean block
# devices have been enumerated — udev coldplug runs in parallel with it. On
# q35 (ProxmoxProvider::DEFAULT_MACHINE_TYPE) the NoCloud CD-ROM hangs off the
# ich9-ahci SATA controller, so /dev/sr0 appears only once the ahci module has
# loaded, probed, and udev has created the node. A single-shot check races
# that.
#
# It lost the race on ops-cell's FIRST boot (2026-07-29): the stager took the
# no-op exit below, nothing staged /run/powernode/identity.cfg, and the agent
# looped "identity: not found by this strategy" forever. `qm stop && qm start`
# — different timing — fixed it. The failure is SILENT because this same exit
# is the correct, common behaviour for a node with no CD-ROM at all, so
# nothing anywhere reports an error.
#
# udevadm settle returns as soon as the event queue drains, NOT after the full
# timeout, so a node that genuinely has no optical device still exits fast —
# the "latency-free" property of the original check is preserved for it. The
# short poll afterwards covers a node landing just after settle returns.
if ! cidata_device_present; then
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout="${CIDATA_SETTLE_TIMEOUT:-15}" >/dev/null 2>&1 || true
    fi
    waited=0
    while [ "$waited" -lt "${CIDATA_WAIT_SECONDS:-10}" ] && ! cidata_device_present; do
        sleep 1
        waited=$((waited + 1))
    done
    [ "$waited" -gt 0 ] && log "waited ${waited}s for a NoCloud drive to enumerate"
fi

if ! cidata_device_present; then
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
    # Content-route: federation user-data is always a JSON object; enrollment
    # identity.cfg never is. Read just the first line with the shell's own
    # `read` builtin (no external `head`/`grep` dependency needed pre-pivot).
    first_line=""
    IFS= read -r first_line < "$MNT/user-data" 2>/dev/null || true

    case "$first_line" in
        "{"*)
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
            ;;
        *)
            # Option 3 enrollment identity — sourced-shell identity.cfg
            # (ID=/KEY=/SERVER=/CA_PEM_FILE=), rendered by
            # System::Providers::Proxmox::EnrollmentSeed#render_cicustom.
            # KEY= carries a single-use bootstrap token in cleartext, so the
            # same 0600 umask discipline as the federation branch applies.
            mkdir -p /run/powernode
            umask 077
            rm -f "$IDENTITY_DEST"
            if cp "$MNT/user-data" "$IDENTITY_DEST" && chmod 0600 "$IDENTITY_DEST"; then
                log "staged enrollment identity -> $IDENTITY_DEST (0600)"
            else
                log "WARN: failed to stage user-data -> $IDENTITY_DEST"
            fi
            # meta-data carries the raw CA PEM (a public cert chain, not
            # secret) that CA_PEM_FILE= in identity.cfg points at — 0644 is
            # fine, mirroring the federation branch's own CA-is-public
            # posture (see EnrollmentSeed's ca_pem class doc).
            if [ -s "$MNT/meta-data" ]; then
                if cp "$MNT/meta-data" "$ENROLL_CA_DEST" && chmod 0644 "$ENROLL_CA_DEST"; then
                    log "staged enrollment CA -> $ENROLL_CA_DEST (0644)"
                else
                    log "WARN: failed to stage meta-data -> $ENROLL_CA_DEST"
                fi
            else
                log "WARN: identity.cfg staged but no meta-data (CA PEM) present on the cidata drive"
            fi
            ;;
    esac
else
    log "cidata drive has no non-empty user-data — nothing to stage"
fi

umount "$MNT" 2>/dev/null || true
exit 0
