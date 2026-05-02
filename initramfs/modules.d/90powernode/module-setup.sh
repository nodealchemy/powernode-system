#!/usr/bin/env bash
# Powernode dracut module — installs the powernode-agent binary, the early
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
# Prefer systemd-networkd over the legacy network module — Ubuntu 24.04 ships
# systemd-networkd by default and dropped isc-dhcp-client (which "network-legacy"
# depends on) from the base install. systemd-resolved gives us /etc/resolv.conf
# wired to networkd's DHCP-discovered DNS servers — without it the agent's
# Go net.Resolver falls back to ::1:53 and fails closed.
depends() {
    echo "systemd-networkd systemd-resolved base systemd"
    return 0
}

install() {
    # The Go powernode-agent. Build.sh stages a per-arch binary at /tmp/powernode-agent
    # before invoking dracut and supplies it via --include. This stub
    # entry guards the case where the binary is missing during local
    # development; production builds always have the binary present.
    if [[ -x "/tmp/powernode-agent" ]]; then
        inst /tmp/powernode-agent /sbin/powernode-agent
    fi

    # Early-boot init hook — runs after dracut's own pre-mount phase.
    # Lives in /sbin so systemd's emergency shell can also invoke it.
    # Used in production-mode boot (real disk → switch_root flow); a no-op
    # for direct-kernel-boot smoke tests because dracut never enters
    # pre-mount when there is no `root=` kernel arg.
    inst_hook pre-mount 90 "${moddir}/init-powernode.sh"

    # Systemd unit for the long-lived agent loop. Active when dracut hands
    # off to systemd-in-initramfs (i.e. smoke test / recovery boot — no
    # switch_root). On production boots the new rootfs replaces /etc on
    # switch_root, dropping this unit; the system-base module's own
    # powernode-agent.service takes over from there.
    inst_simple "${moddir}/powernode-agent.service" \
        /etc/systemd/system/powernode-agent.service
    mkdir -p "${initdir}/etc/systemd/system/multi-user.target.wants"
    ln -sf ../powernode-agent.service \
        "${initdir}/etc/systemd/system/multi-user.target.wants/powernode-agent.service"

    # Default DHCP for any en*/eth* interface — pre-enrollment fallback so
    # systemd-networkd brings the link up before the agent's first dial-home.
    # The agent overrides this with instance-specific policy after enrollment.
    inst_simple "${moddir}/90-default-dhcp.network" \
        /etc/systemd/network/90-default-dhcp.network

    # ─────────────────────────────────────────────────────────────────────
    # OpenSSH server for smoke-test interactive access. Production switch_roots
    # to system-base which has its own sshd in the module rootfs. This block
    # only matters in the initramfs context (no switch_root happens for smoke
    # test direct-kernel-boot). The agent fetches authorized_keys from the
    # platform via /node_api/config/authorized_keys after enrollment and writes
    # them to /root/.ssh/authorized_keys.
    # ─────────────────────────────────────────────────────────────────────
    inst_multiple sshd ssh-keygen

    # Minimal sshd config: pubkey-only, no PAM (avoids PAM module deps).
    inst_simple "${moddir}/sshd_config" /etc/ssh/sshd_config

    # NSS config — without this, sshd's getpwnam("sshd") fails despite the
    # user existing in /etc/passwd, because libnss has no instructions on
    # which backends to consult.
    inst_simple "${moddir}/nsswitch.conf" /etc/nsswitch.conf

    # Privilege-separation runtime dir.
    mkdir -p "${initdir}/run/sshd"
    chmod 0755 "${initdir}/run/sshd"

    # /root/.ssh — agent writes authorized_keys here on first heartbeat tick.
    mkdir -p "${initdir}/root/.ssh"
    chmod 0700 "${initdir}/root/.ssh"

    # Add sshd privsep user to /etc/passwd if not already present.
    # Initramfs's /etc/passwd is provided by base/systemd dracut modules; we
    # extend it. nogroup (gid 65534) is the default group for system services.
    if ! grep -q '^sshd:' "${initdir}/etc/passwd" 2>/dev/null; then
        echo 'sshd:x:120:65534::/run/sshd:/usr/sbin/nologin' >> "${initdir}/etc/passwd"
    fi
    if ! grep -q '^nogroup:' "${initdir}/etc/group" 2>/dev/null; then
        echo 'nogroup:x:65534:' >> "${initdir}/etc/group"
    fi

    # sshd unit + host-key generator oneshot. ssh-keygen runs Before sshd.
    inst_simple "${moddir}/powernode-ssh-keygen.service" \
        /etc/systemd/system/powernode-ssh-keygen.service
    inst_simple "${moddir}/sshd.service" /etc/systemd/system/sshd.service
    ln -sf ../sshd.service \
        "${initdir}/etc/systemd/system/multi-user.target.wants/sshd.service"
    mkdir -p "${initdir}/etc/systemd/system/sshd.service.wants"
    ln -sf ../powernode-ssh-keygen.service \
        "${initdir}/etc/systemd/system/sshd.service.wants/powernode-ssh-keygen.service"

    # ─────────────────────────────────────────────────────────────────────
    # powernode-mount oneshot — runs `prepare-root` then `systemctl switch-root`
    # to pivot into the module-rootfs union. Active only when the host's 9p
    # share + at least the system-base module are accessible at boot.
    # ─────────────────────────────────────────────────────────────────────
    inst_simple "${moddir}/powernode-mount.service" \
        /etc/systemd/system/powernode-mount.service
    ln -sf ../powernode-mount.service \
        "${initdir}/etc/systemd/system/multi-user.target.wants/powernode-mount.service"

    # mount(8) is needed by prepare-root to wire up 9p, overlayfs, and binds.
    inst_multiple mount

    # /sysroot is the conventional switch-root target. systemd's switch-root
    # implementation expects this dir to exist before it executes.
    mkdir -p "${initdir}/sysroot"

    # /persist as its own tmpfs (NOT a subdir of the initramfs rootfs).
    # Critical: rbind-mounting /persist into /sysroot/persist only carries
    # contents forward across switch-root if /persist is a SEPARATE filesystem
    # — switch-root frees the initramfs's rootfs, so any state written into
    # /persist-as-a-subdir vanishes when the initramfs tmpfs is unmounted.
    inst_simple "${moddir}/persist.mount" /etc/systemd/system/persist.mount
    mkdir -p "${initdir}/etc/systemd/system/local-fs.target.wants"
    ln -sf ../persist.mount \
        "${initdir}/etc/systemd/system/local-fs.target.wants/persist.mount"
    mkdir -p "${initdir}/persist"

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
