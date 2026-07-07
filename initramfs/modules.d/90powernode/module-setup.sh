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

# Need overlay + erofs for union mounts; need network for enrollment.
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
    # shellcheck disable=SC2154  # moddir is provided by dracut
    inst_hook pre-mount 90 "${moddir}/init-powernode.sh"

    # Systemd unit for the long-lived agent loop. Active when dracut hands
    # off to systemd-in-initramfs (i.e. smoke test / recovery boot — no
    # switch_root). On production boots the new rootfs replaces /etc on
    # switch_root, dropping this unit; the system-base module's own
    # powernode-agent.service takes over from there.
    inst_simple "${moddir}/powernode-agent.service" \
        /etc/systemd/system/powernode-agent.service
    # shellcheck disable=SC2154  # initdir is provided by dracut
    mkdir -p "${initdir}/etc/systemd/system/multi-user.target.wants"
    ln -sf ../powernode-agent.service \
        "${initdir}/etc/systemd/system/multi-user.target.wants/powernode-agent.service"

    # federation-accept oneshot — runs Before=powernode-agent.service.
    # Reads spawn payload from fw-cfg (parent_url + acceptance_token +
    # spawn_mode + parent_peer_id + contract_version), POSTs the accept
    # handshake, captures node_enrollment.bootstrap_token from the response,
    # and enrolls — node cert lands at /persist (survives the dracut→
    # system-base switch_root via persist.mount). Idempotent via the marker
    # at /var/lib/powernode-agent/federation-accepted. No-op (exit 0) when
    # fw-cfg has no parent_url, which is the legitimate steady-state for
    # operator-driven manual provisions. Required for bare-metal/PXE/
    # pivot_root deployments where there's no cloud-init runcmd to invoke
    # federation-accept; cloud-init paths are also safe (their runcmd
    # invocation short-circuits on the marker).
    inst_simple "${moddir}/powernode-federation-accept.service" \
        /etc/systemd/system/powernode-federation-accept.service
    ln -sf ../powernode-federation-accept.service \
        "${initdir}/etc/systemd/system/multi-user.target.wants/powernode-federation-accept.service"

    # NoCloud federation-payload stager — runs Before powernode-federation-accept.
    # PVE spawns under a non-root API token can't use fw-cfg, so the provider
    # ships the federation payload on a cloud-init NoCloud CD-ROM (ide2 cloudinit)
    # instead. The UKI pivot-boot image has no cloud-init to process it, so this
    # oneshot mounts that CD-ROM read-only and copies its user-data VERBATIM to
    # /etc/powernode/federation-payload.json — the agent's file fallback (see
    # agent/internal/federation/config.go). Safe no-op when no such CD-ROM is
    # present (bare-metal / local_qemu / direct-kernel). Full rationale in the
    # script header. Needs isofs + optical drivers (added in build.sh /
    # dracut.conf.d) to see + mount the drive.
    inst_simple "${moddir}/powernode-cidata-payload.sh" /sbin/powernode-cidata-payload
    inst_simple "${moddir}/powernode-cidata-payload.service" \
        /etc/systemd/system/powernode-cidata-payload.service
    ln -sf ../powernode-cidata-payload.service \
        "${initdir}/etc/systemd/system/multi-user.target.wants/powernode-cidata-payload.service"

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

    # /persist — DISK-BACKED (baked ext4 p2, label "persist") so PKI + module
    # cache survive reboots. Still a SEPARATE filesystem, so rbind-mounting
    # /persist into /sysroot/persist carries contents forward across switch-root
    # (switch-root frees the initramfs rootfs, so /persist-as-a-subdir would
    # vanish). A SINGLE oneshot (persist-setup.service) does the whole thing:
    # `udevadm settle` → if the "persist" label resolves, grow + mount ext4;
    # else tmpfs fallback. Centralized to kill a udev race — the earlier
    # persist.mount/persist-grow/persist-fallback trio used one-shot
    # ConditionPathExists checks, and the negated fallback could tmpfs-mount
    # /persist before udev linked the by-label symlink.
    inst_simple "${moddir}/persist-setup.service" /etc/systemd/system/persist-setup.service
    mkdir -p "${initdir}/etc/systemd/system/local-fs.target.wants"
    ln -sf ../persist-setup.service \
        "${initdir}/etc/systemd/system/local-fs.target.wants/persist-setup.service"
    mkdir -p "${initdir}/persist"

    # persist-setup shells out to: udevadm (settle for the coldplug queue),
    # blkid (resolve the label), blockdev (read the size), sfdisk (bounded
    # partition resize), partx (refresh the kernel view), resize2fs (grow the
    # ext4 fs), mount (mount ext4 or tmpfs; already staged below for prepare-root).
    inst_multiple udevadm sfdisk resize2fs partx blkid blockdev

    # /boot — FAT32 boot partition (label BOOT) holding identity.cfg +
    # powernode-ca.pem: the claim-flow identity source for UEFI-disk /
    # pivot_root boots. Mounted Before powernode-agent.service so
    # BootIdentityStrategy reads it; nofail so cloud/non-pivot boots (no
    # BOOT partition) fall through to other identity strategies. The dracut
    # pre-mount hook can't do this here — we boot multi-user.target, not the
    # initrd sequence — so it must be a systemd mount unit, like persist.mount.
    inst_simple "${moddir}/boot.mount" /etc/systemd/system/boot.mount
    ln -sf ../boot.mount \
        "${initdir}/etc/systemd/system/local-fs.target.wants/boot.mount"

    # Tools we lean on at boot. chmod: powernode-cidata-payload.sh pins the
    # staged federation-payload.json to 0600 (it embeds a single-use token).
    inst_multiple ip mount umount mkdir cp ln rm chmod sleep sha256sum

    # nftables `nft` — the reconciler's module egress-policy applier shells out
    # to `nft` to create per-module filter chains. Absent from the initramfs,
    # egress apply failed with `nft: executable file not found in $PATH` on
    # every module. The nf_tables kernel module is force-included via build.sh.
    inst_multiple nft

    # Cosign trust root + Sigstore Fulcio root.
    # Pinned per-build via $POWERNODE_FULCIO_ROOT env. Default to the
    # public Sigstore root if not set; production should always pin.
    if [[ -n "${POWERNODE_FULCIO_ROOT:-}" && -f "${POWERNODE_FULCIO_ROOT}" ]]; then
        inst "${POWERNODE_FULCIO_ROOT}" /etc/powernode/fulcio-root.pem
    fi

    # System CA bundle — required for Go's crypto/x509 to verify TLS
    # certs the agent encounters during enrollment (federation_api/accept,
    # node_api/enroll). Without this, the agent dies with
    # "x509: certificate signed by unknown authority" on the first HTTPS
    # call to the platform. Go's default cert pool path probes
    # /etc/ssl/certs/ca-certificates.crt (Debian/Ubuntu),
    # /etc/pki/tls/certs/ca-bundle.crt (RHEL), and a few others.
    # Installing the Debian bundle at its canonical path covers our build
    # environment; for production we may eventually swap in a fw-cfg
    # ca_pem (ProxmoxProvider's CloudSeed already supports it) to allow
    # private CAs without trusting the global Mozilla bundle.
    if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
        inst /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
    fi

    # Mark the module as Powernode-installed so the agent can self-identify.
    mkdir -p "${initdir}/etc/powernode"
    echo "powernode-initramfs-module=1" >"${initdir}/etc/powernode/module.conf"
}
