#!/usr/bin/env bash
# Powernode dracut module — installs the ipn-agent binary, the early
# init hook, and the cosign trust roots into the initramfs.
#
# Reference: Golden Eclipse plan M3 — initramfs builder modules.d.
#
# Dracut calls these functions in the following order:
#   check          — return 0 if module should be included
#   depends        — return list of required modules
#   install        — install files into initramfs build root
#   installkernel  — install kernel module deps (handled via add_drivers)

# Always include the powernode module when build.sh asks for it.
check() {
    return 0
}

# Need overlay + composefs for union mounts; need network for enrollment.
depends() {
    echo "network base systemd"
    return 0
}

install() {
    # The Go ipn-agent. Build.sh stages a per-arch binary at /tmp/ipn-agent
    # before invoking dracut and supplies it via --include. This stub
    # entry guards the case where the binary is missing during local
    # development; production builds always have the binary present.
    if [[ -x "/tmp/ipn-agent" ]]; then
        inst /tmp/ipn-agent /sbin/ipn-agent
    fi

    # Early-boot init hook — runs after dracut's own pre-mount phase.
    # Lives in /sbin so systemd's emergency shell can also invoke it.
    inst_hook pre-mount 90 "${moddir}/init-powernode.sh"

    # Tools we lean on at boot.
    inst_multiple ip mount umount mkdir cp ln rm sleep sha256sum

    # Cosign trust root + Sigstore Fulcio root.
    # Pinned per-build via $POWERNODE_FULCIO_ROOT env. Default to the
    # public Sigstore root if not set; production should always pin.
    if [[ -n "${POWERNODE_FULCIO_ROOT:-}" && -f "${POWERNODE_FULCIO_ROOT}" ]]; then
        inst "${POWERNODE_FULCIO_ROOT}" /etc/powernode/fulcio-root.pem
    fi

    # Mark the module as Powernode-installed so the agent can self-identify.
    mkdir -p "${initdir}/etc/powernode"
    echo "powernode-initramfs-module=1" >"${initdir}/etc/powernode/module.conf"
}
