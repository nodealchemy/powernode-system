#!/usr/bin/env bash
# Multi-arch boot artifact builder for the Powernode system extension.
#
# Reference: Golden Eclipse plan M3. Produces six artifact families per arch:
#   1. kernel + initramfs bundle (PXE/iPXE network boot, libvirt direct)
#   2. raw disk image (.img — USB stick / SD card / direct dd)
#   3. ISO 9660 image (.iso — DVD/USB, IPMI virtual media)
#   4. iPXE chainload script (.ipxe — network-boot entry point)
#   5. cloud qcow2 image (.qcow2 — libvirt/QEMU pre-baked rootfs)
#   6. OCI image (bootc-compatible, container-image-as-OS)
#
# Usage:
#   ./build.sh --arch amd64 [--variants kernel-initrd,raw,iso,ipxe,qcow2,oci]
#   ./build.sh --arch arm64 [--variants ...]
#
# All variants are built by default. Use --variants to restrict.
#
# Outputs land at: build/<arch>/<variant>/...
#
# Pinning: BASE_IMAGE_DIGEST + KERNEL_PACKAGE_VERSION + COMPOSEFS_TOOLS_VERSION
# are injected from CI workflow inputs to honor the M1 reproducibility gate.
# Re-running the build with the same pins on the same source must produce
# identical SHA-256 digests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_VARIANTS="kernel-initrd,raw,iso,ipxe,qcow2,oci,disk-image-rpi4,disk-image-arm64-uefi,disk-image-amd64-uefi"
# Sentinel: build.sh fails loudly if a real digest isn't supplied (via
# BASE_IMAGE_DIGEST env, --base-image arg, or CI workflow input). Per M3
# reproducibility, no placeholder is ever permitted past the build gate.
readonly DEFAULT_BASE_IMAGE="REQUIRED_PIN_NOT_SET"

ARCH=""
VARIANTS="${DEFAULT_VARIANTS}"
BASE_IMAGE_DIGEST="${BASE_IMAGE_DIGEST:-${DEFAULT_BASE_IMAGE}}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/build}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --arch {amd64|arm64} [options]

Required:
  --arch         Target architecture (amd64 or arm64)

Optional:
  --variants     Comma-separated list of variants to build.
                 Default: ${DEFAULT_VARIANTS}
  --output-dir   Output root (default: \${SCRIPT_DIR}/build)
  --base-image   Pinned base image digest (default: \$BASE_IMAGE_DIGEST env)
  --help         Show this help

Examples:
  $(basename "$0") --arch amd64
  $(basename "$0") --arch arm64 --variants kernel-initrd,iso
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)        ARCH="$2"; shift 2 ;;
    --variants)    VARIANTS="$2"; shift 2 ;;
    --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
    --base-image)  BASE_IMAGE_DIGEST="$2"; shift 2 ;;
    --help|-h)     usage 0 ;;
    *)             echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -z "${ARCH}" ]] && { echo "ERROR: --arch is required" >&2; usage 1; }
[[ "${ARCH}" =~ ^(amd64|arm64)$ ]] || { echo "ERROR: --arch must be amd64 or arm64" >&2; exit 1; }

readonly ARCH_OUT="${OUTPUT_DIR}/${ARCH}"
mkdir -p "${ARCH_OUT}"

log() { echo "[$(date -Iseconds)] [$ARCH] $*"; }

# ── Variant: kernel + initramfs bundle ─────────────────────────────────────
build_kernel_initrd() {
  log "Building kernel + initramfs (dracut)…"
  local out="${ARCH_OUT}/kernel-initrd"
  mkdir -p "${out}"

  # Kernel module list per architecture.
  local arch_conf="${SCRIPT_DIR}/dracut.conf.d/powernode-${ARCH}.conf"
  local shared_conf="${SCRIPT_DIR}/dracut.conf.d/powernode.conf"

  # Compose dracut module path so /sbin/powernode-agent is embedded into initramfs
  # along with the powernode module-setup hook (modules.d/90powernode/).
  if ! command -v dracut >/dev/null 2>&1; then
    log "WARN: dracut not in PATH — emitting placeholder for offline planning"
    echo "placeholder kernel for ${ARCH}" >"${out}/kernel"
    echo "placeholder initramfs for ${ARCH}" >"${out}/initramfs.cpio.zst"
    return 0
  fi

  local kver
  # Prefer KERNEL_VERSION env override → running kernel → newest kernel that
  # has both modules and a /boot/vmlinuz-${kver}. Avoid orphaned module dirs
  # (modules present but no kernel image — common after partial kernel removals).
  if [[ -n "${KERNEL_VERSION:-}" ]] && [[ -d "/lib/modules/${KERNEL_VERSION}" ]] && [[ -f "/boot/vmlinuz-${KERNEL_VERSION}" ]]; then
    kver="${KERNEL_VERSION}"
  elif [[ -d "/lib/modules/$(uname -r)" ]] && [[ -f "/boot/vmlinuz-$(uname -r)" ]]; then
    kver="$(uname -r)"
  else
    kver="$(for d in /lib/modules/*/; do
              v=$(basename "$d"); [[ -f "/boot/vmlinuz-${v}" ]] && echo "$v";
            done | sort -V | tail -n1)"
  fi
  if [[ -z "${kver}" ]]; then
    log "ERROR: no kernel with both modules and /boot/vmlinuz-* found" >&2
    return 1
  fi

  # The agent binary must be present before we can embed it into the initramfs.
  # Two acceptable sources (checked in order):
  #   1. scripts/powernode-agent-<arch>          — staged by CI before invoking build.sh
  #   2. ../agent/dist/powernode-agent-linux-<arch>  — produced by `make -C agent build-<arch>`
  #
  # If neither exists, the build FAILS unless POWERNODE_OFFLINE_DEV=1 is set,
  # in which case we invoke the Makefile target to build the agent. The legacy
  # placeholder shim path is removed — a /bin/sh exec disguised as powernode-agent
  # is never acceptable in production (silent non-functional boot).
  local agent_candidates=(
    "${SCRIPT_DIR}/scripts/powernode-agent-${ARCH}"
    "${SCRIPT_DIR}/../agent/dist/powernode-agent-linux-${ARCH}"
  )
  local agent_bin=""
  for c in "${agent_candidates[@]}"; do
    [[ -x "$c" ]] && { agent_bin="$c"; break; }
  done
  if [[ -z "$agent_bin" ]]; then
    if [[ "${POWERNODE_OFFLINE_DEV:-0}" == "1" ]]; then
      log "OFFLINE-DEV: invoking 'make -C ../agent build-${ARCH}' to produce agent binary"
      make -C "${SCRIPT_DIR}/../agent" "build-${ARCH}"
      agent_bin="${SCRIPT_DIR}/../agent/dist/powernode-agent-linux-${ARCH}"
      [[ -x "$agent_bin" ]] || { log "FATAL: make build-${ARCH} did not produce $agent_bin"; exit 1; }
    else
      log "FATAL: agent binary missing for ${ARCH}"
      log "  Looked at:"
      for c in "${agent_candidates[@]}"; do log "    - $c"; done
      log "  CI must stage the artifact before invoking build.sh."
      log "  For local dev, set POWERNODE_OFFLINE_DEV=1 to auto-build via make."
      exit 1
    fi
  fi
  # [[ -x ]] alone only proves the file is executable, not that it's a real
  # binary — a curl fetch that silently lands on an HTTP 200 SPA-fallback
  # page (the platform's /agent route answers a missing artifact that way,
  # not with a 404) produces an executable-bit-set HTML file that passed
  # every check above. Verify the ELF magic before it gets baked into the
  # image: this is the last chokepoint before a silently non-functional boot.
  if [[ "$(head -c4 "$agent_bin" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
    log "FATAL: $agent_bin is not an ELF binary (magic byte check failed)"
    log "  First bytes: $(head -c64 "$agent_bin" | tr -cd '[:print:]\n' | head -c120)"
    log "  This usually means the fetch URL served a fallback page (e.g. SPA"
    log "  HTML for a missing route) instead of the real binary — check"
    log "  POWERNODE_AGENT_BINARY_URL and the /agent route's 404 behavior."
    exit 1
  fi
  cp "$agent_bin" /tmp/powernode-agent

  local conf_args=("-c" "${shared_conf}")
  [[ -f "${arch_conf}" ]] && conf_args+=("-c" "${arch_conf}")

  # Drivers explicitly forced in: dracut config-file merging via repeated -c is
  # unreliable across distros; CLI --force-drivers is the durable mechanism.
  # qemu_fw_cfg exposes virtio-fw-cfg under /sys/firmware/ for the agent's
  # identity package on libvirt/QEMU first boot.
  # 9p / 9pnet_virtio: filesystem passthrough from host (used by the dev-mode
  # local-fs module loader to expose /var/lib/powernode/modules into the guest).
  # overlay: union mount for stacking module rootfs lowers.
  # vfat + nls_*: the FAT32 boot partition (label BOOT) carries the claim-flow
  # identity.cfg; boot.mount needs vfat (+ codepage/iocharset NLS modules) to
  # mount it at /boot. Absent → "unknown filesystem type vfat" and the agent
  # never reads /boot/identity.cfg.
  # isofs: powernode-cidata-payload.sh mounts the PVE cloud-init NoCloud CD-ROM
  # (ISO9660) to stage the federation payload for token-auth Proxmox spawns.
  # CONFIG_ISO9660_FS=m on Ubuntu generic, so it must be force-included (dracut
  # wouldn't auto-detect it — there's no iso9660 rootfs).
  # ahci: the SATA controller driver for that same CD-ROM. The Proxmox provider
  # spawns VMs with machine type q35 (ProxmoxProvider::DEFAULT_MACHINE_TYPE), and
  # on q35 the cloud-init CD-ROM (attached as ide2,media=cdrom) is presented by
  # QEMU through the ich9-ahci SATA controller — q35 has no legacy PIIX3 IDE, so
  # the *builtin* ata_piix never binds it and /dev/sr0 never enumerates without
  # ahci. ahci is CONFIG_SATA_AHCI=m (a loadable module, NOT a builtin), so it
  # must be force-included or powernode-cidata-payload.sh exits at its
  # `[ ! -b /dev/sr0 ]` guard and the federation payload is never staged (child
  # then falls back to the node-claim poll loop and never enrolls). Its block/
  # char deps (sr_mod, cdrom, libata) ARE CONFIG_*=y builtins — already in the
  # kernel, so NOT listed here (per dracut.conf.d/powernode-amd64.conf, builtins
  # must not be listed as drivers); dracut auto-pulls ahci's module dep libahci.
  # erofs: the on-disk format EVERY NodeModule rootfs is published as — the
  # agent's mount/ loop-mounts each module blob with `mount -t erofs`
  # (internal/mount/erofs.go). Pre-pivot ComposeForPivot builds the union root
  # from these erofs lowers, so without erofs the initramfs can mount NO module
  # — including base-os-ubuntu-noble, which itself ships as an erofs blob:
  # chicken-and-egg, the module that would provide erofs.ko can't be mounted
  # without erofs.ko. (An earlier version of this comment claimed base-os
  # "carries the full /lib/modules tree". That is FALSE and was actively
  # misleading in exactly this file: base-os-ubuntu-noble's package_spec
  # contains no linux-* package at all, the rootfs is an mmdebstrap minbase,
  # and live nodes have no /lib/modules — which is WHY this whole
  # force_drivers list exists. See the nf_tables writeup 17 lines below.) Result is an agent-only
  # pivot with zero app modules (postgres/Rails/…) composed. erofs is
  # CONFIG_EROFS_FS=m on Ubuntu 24.04, so — like isofs/ahci above — it must be
  # force-included; dracut won't auto-detect it (no erofs rootfs at build time).
  # Post-pivot capabilities.go's erofs_available gate ALSO skips module
  # reconcile when erofs is unmountable, so its absence silently yields a hub
  # that enrolls but runs none of its 11 modules.
  # ext4: persist.mount now mounts the baked ext4 "persist" partition (label
  # persist) for reboot-surviving PKI + module cache — the initramfs must be
  # able to mount ext4. CONFIG_EXT4_FS=m on Ubuntu 24.04, and there's no ext4
  # rootfs at build time, so dracut won't auto-include it; force it (same class
  # as erofs/isofs/ahci above).
  # nf_tables (+ nft_ct + nf_conntrack): the POST-pivot steady-state reconciler
  # (agent/internal/runtime/reconcile.go attachModule → security.ApplyEgress-
  # Allowlist) shells out to `nft` to install each module's default-deny egress
  # chain BEFORE rendering its units. The pivot rootfs (base-os-ubuntu-noble is
  # an mmdebstrap minbase — it ships NO kernel package, so no netfilter .ko), so
  # the first `nft add table inet ...` died with "Unable to initialize Netlink
  # socket: Protocol not supported" (nf_tables.ko never loaded → the NFNETLINK
  # subsystem is unregistered) → attachModule returns early → postgres/redis/
  # traefik and every other module's units stay empty and never start (BUG-J).
  # These are CONFIG_*=m on Ubuntu 24.04 (all in linux-modules, NOT -extra), so
  # dracut won't auto-detect them (no nftables ruleset at build time) — force
  # them into the initramfs /lib/modules. The modules-load.d drop-in +
  # powernode-mount ExecStartPre (see module-setup.sh) then modprobe them BEFORE
  # switch_root; because switch_root keeps the SAME running kernel, a module
  # loaded pre-pivot stays loaded, so the post-pivot reconciler's `nft` talks to
  # an already-registered subsystem and never needs the pivot rootfs to carry a
  # /lib/modules tree. dracut auto-pulls the modinfo deps (nfnetlink for
  # nf_tables; nf_conntrack for nft_ct). The inet-family filter/output ruleset
  # with `ct state established,related` needs nft_ct (the ct expr) + nf_conntrack
  # (conntrack core) on top of nf_tables — all three are force-listed so the
  # whole egress ruleset applies, not just the table create.
  # bridge (+ br_netfilter, llc, stp): same class of gap as nf_tables above,
  # hitting dockerd's default network instead of the egress reconciler.
  # dev-cell-docker's dockerd (services: default bridge networking, unlike
  # gitea-act-runner's --bridge=none) died with "Failed to create bridge
  # docker0 via netlink: operation not supported" — the pivot rootfs ships
  # no /lib/modules (same mmdebstrap-minbase chicken-and-egg as erofs/nf_tables
  # above), so CONFIG_BRIDGE=m/CONFIG_BRIDGE_NETFILTER=m never get an on-disk
  # .ko to autoload from. llc + stp are bridge.ko's own hard module deps
  # (802.2 LLC + spanning tree) — force-listed explicitly for the same
  # clarity reason nft_ct/nf_conntrack are spelled out above rather than left
  # to dracut's dep resolution alone.
  # nf_nat (+ nft_masq, xt_MASQUERADE): discovered on the FIRST real-boot
  # verification of the bridge fix above — bridge/br_netfilter/llc/stp let
  # dockerd create docker0, but `iptables -t nat -I POSTROUTING ... -j
  # MASQUERADE` then died with "Extension MASQUERADE revision 0 not
  # supported, missing kernel module?" + "CHAIN_ADD failed: chain
  # POSTROUTING" — the nat table itself never got created because nf_nat
  # was never force-included (dracut's dep resolution only pulls a
  # requested module's OWN deps, never modules that depend ON it, so
  # nf_nat being absent was invisible until something needed the nat
  # table). nft_masq is the nftables-backend MASQUERADE target iptables-nft
  # actually invokes; xt_MASQUERADE is kept alongside for the legacy-xtables
  # compat path. nf_nat's own hard dep (nf_conntrack) is already force-
  # listed above.
  # nft_chain_nat: nf_nat alone was NOT enough — `nft add table ip nat`
  # succeeds (an empty table shell needs nothing special), but `nft add
  # chain ip nat POSTROUTING '{ type nat hook postrouting ... }'` then died
  # with "No such file or directory": nf_tables' "nat" CHAIN TYPE (the hook
  # registration that lets a chain declare `type nat`) is a SEPARATE module
  # from nf_nat (the NAT rewrite engine) and from nft_masq (the MASQUERADE
  # target expression) — none of their modinfo deps pull it in, since
  # dracut's resolution only follows "requires", never "is required by".
  # Depends only on nf_nat + nf_tables, both already force-listed.
  # nft_compat (+ xt_conntrack, xt_addrtype, xt_tcpudp, xt_multiport): with
  # table/chain/rule all confirmed working via raw `nft` (proving nf_nat/
  # nft_masq/nft_chain_nat above are genuinely sufficient at the nftables
  # level), dockerd's actual `iptables -t nat -I POSTROUTING ... -j
  # MASQUERADE` STILL failed — same "Extension MASQUERADE revision 0 not
  # supported" warning, now "RULE_INSERT/RULE_APPEND failed: No such file or
  # directory". Root cause: dockerd shells out to the `iptables` CLI
  # (xtables-nft-multi), and invoking an xtables-style target/match (like
  # MASQUERADE) THROUGH the nft backend — including the revision-negotiation
  # the warning references — routes through nft_compat, the kernel shim that
  # lets nf_tables evaluate legacy xt_* extensions at all; it is a distinct
  # module from nft_masq (nftables' OWN native masquerade expression, which
  # is why a raw `nft add rule ... masquerade` worked fine while `iptables
  # -j MASQUERADE` didn't). xt_conntrack/xt_addrtype/xt_tcpudp/xt_multiport
  # are docker's other default-bridge iptables extensions (ICC forwarding's
  # conntrack state match, port-publish's tcp/udp + multiport match) —
  # force-included alongside nft_compat rather than discovering each via a
  # separate round-trip, since they are dockerd's fixed, well-known default
  # rule set, not speculative additions.
  # veth: with docker0 bridge creation AND its NAT/MASQUERADE rule both
  # confirmed working (nf_nat/nft_masq/nft_chain_nat/nft_compat above all
  # verified sufficient), `docker run` still failed — this time actually
  # RUNNING a container, at endpoint creation: "failed to add the host
  # <=> sandbox veth pair interfaces: operation not supported". veth is the
  # driver for the virtual ethernet pair connecting a container's network
  # namespace to the host bridge — only exercised once a container is
  # actually started (not at daemon startup, which is why this stayed
  # invisible through every prior round). Zero module dependencies of its
  # own.
  # wireguard + vrf + dummy: the SDWAN data plane's three netdev types —
  # same mmdebstrap-minbase /lib/modules gap as bridge/veth above, hitting
  # the agent's post-pivot SDWAN appliers instead of dockerd. Proven
  # 2026-08-20 on two freshly provisioned Proxmox nodes and reproduced on
  # dev-cell: every 30s reconcile tick logs "apply_vrfs: create vrf
  # sdwan-1: ip link add: exit status 2; Error: Unknown device type", then
  # the same for wg-sdwan-1 — apply_vrfs dies before wg_applier runs, so
  # the SDWAN overlay can never exist. All three are CONFIG_*=m on Ubuntu
  # 24.04 generic (none builtin — verified empirically on a live node: no
  # dummy_setup/wg_socket_init/vrf_newlink symbols in /proc/kallsyms, and
  # `ip link add ... type dummy` fails "Unknown device type" just like
  # wireguard/vrf), and there is no on-disk /lib/modules post-pivot to
  # autoload them from.
  # wireguard — wg_applier's `ip link add <ifname> type wireguard`
  # (agent/internal/sdwan/wg_applier.go). Its modinfo deps (udp_tunnel,
  # ip6_udp_tunnel, plus the chacha20/poly1305/curve25519 crypto lib
  # modules) are the module's OWN deps, so dracut's dep resolution pulls
  # them (same as nfnetlink for nf_tables / libahci for ahci above) —
  # deliberately NOT hand-listed here because the crypto lib names are
  # ARCH-SPECIFIC (curve25519-x86_64 on amd64 vs -neon on arm64) and any
  # name missing on the build host fails the entire dracut-install batch.
  # vrf — vrf_applier's `ip link add <name> type vrf table <id>`. Zero
  # modinfo deps of its own; its l3mdev core is CONFIG_NET_L3_MASTER_DEV=y
  # (a builtin bool, so NOT listed — see dracut.conf.d/powernode-amd64.conf
  # on builtins failing the batch).
  # dummy — vip_applier's VIP anchor interfaces (`ip link add <name> type
  # dummy`). Included NOW rather than discovered on the next real-boot
  # verification the way nf_nat → nft_chain_nat → nft_compat → veth each
  # cost a separate round-trip: with wireguard+vrf fixed, the very next
  # thing the SDWAN reconciler does is create VIP dummies.
  # (`ip rule` needs nothing here: fib_rules is builtin — fib_rules_register
  # is present in /proc/kallsyms on the same kernel.)
  local force_drivers="qemu_fw_cfg 9p 9pnet 9pnet_virtio overlay vfat nls_cp437 nls_ascii nls_iso8859-1 isofs ahci erofs ext4 nf_tables nft_ct nf_conntrack bridge br_netfilter llc stp nf_nat nft_masq xt_MASQUERADE nft_chain_nat nft_compat xt_conntrack xt_addrtype xt_tcpudp xt_multiport veth wireguard vrf dummy nft_nat nft_limit nft_reject nft_reject_inet xt_nat"

  # dracut discovers custom modules ONLY under /usr/lib/dracut/modules.d (there
  # is no CLI flag for an extra search dir). The powernode module-setup hook
  # lives in this repo, so link it into dracut's search path before invoking
  # dracut — otherwise `--modules powernode` fails with "Module 'powernode'
  # cannot be found" in a fresh environment (CI / the arm64 build container).
  # Idempotent; falls back to sudo only when the target dir isn't writable.
  local dracut_moddir="/usr/lib/dracut/modules.d"
  local powernode_mod="${SCRIPT_DIR}/modules.d/90powernode"
  if [[ -d "${powernode_mod}" && ! -e "${dracut_moddir}/90powernode" ]]; then
    ln -sfn "${powernode_mod}" "${dracut_moddir}/90powernode" 2>/dev/null \
      || sudo ln -sfn "${powernode_mod}" "${dracut_moddir}/90powernode"
    log "linked powernode dracut module → ${dracut_moddir}/90powernode"
  fi

  dracut \
    "${conf_args[@]}" \
    --modules "powernode" \
    --kver "${kver}" \
    --force-drivers "${force_drivers}" \
    --include "/tmp/powernode-agent" "/sbin/powernode-agent" \
    --compress zstd \
    --force \
    "${out}/initramfs.cpio.zst"

  # Ubuntu ships /boot/vmlinuz-* with mode 0600 owned by root (since 2018,
  # KASLR consideration). Use sudo for the read; the destination ends up
  # owned by the build user so subsequent runs don't need elevated rights.
  if [[ -r "/boot/vmlinuz-${kver}" ]]; then
    cp "/boot/vmlinuz-${kver}" "${out}/kernel"
  else
    log "kernel image needs sudo (mode 0600 in /boot)…"
    sudo cp "/boot/vmlinuz-${kver}" "${out}/kernel"
    sudo chown "$(id -u):$(id -g)" "${out}/kernel"
  fi
  chmod 0644 "${out}/kernel" "${out}/initramfs.cpio.zst"

  sha256sum "${out}/kernel" "${out}/initramfs.cpio.zst" >"${out}/SHA256SUMS"
  log "kernel-initrd ✓ at ${out} (kver=${kver})"
}

# ── Variant: raw disk image (UEFI ESP + ext4 boot + ext4 persist) ──────────
build_raw() {
  log "Building raw disk image…"
  local out="${ARCH_OUT}/raw"
  mkdir -p "${out}"
  bash "${SCRIPT_DIR}/images/raw/build-raw.sh" --arch "${ARCH}" --output "${out}/installer.img"
  sha256sum "${out}/installer.img" >"${out}/SHA256SUMS" 2>/dev/null || true
  log "raw ✓ at ${out}"
}

# ── Variant: ISO (xorriso, hybrid EFI+BIOS for amd64; pure UEFI for arm64) ──
build_iso() {
  log "Building ISO…"
  local out="${ARCH_OUT}/iso"
  mkdir -p "${out}"
  bash "${SCRIPT_DIR}/images/iso/build-iso.sh" --arch "${ARCH}" --output "${out}/installer.iso"
  sha256sum "${out}/installer.iso" >"${out}/SHA256SUMS" 2>/dev/null || true
  log "iso ✓ at ${out}"
}

# ── Variant: iPXE chainload script (server-rendered template) ──────────────
build_ipxe() {
  log "Building iPXE chainload template…"
  local out="${ARCH_OUT}/ipxe"
  mkdir -p "${out}"
  cp "${SCRIPT_DIR}/images/ipxe/template.ipxe.erb" "${out}/template.ipxe.erb"
  log "ipxe ✓ template copied to ${out} — server's NetbootService renders per-instance"
}

# ── Variant: qcow2 pre-baked cloud image ───────────────────────────────────
build_qcow2() {
  log "Building qcow2 cloud image…"
  local out="${ARCH_OUT}/qcow2"
  mkdir -p "${out}"
  bash "${SCRIPT_DIR}/images/qcow2/build-qcow2.sh" --arch "${ARCH}" --output "${out}/cloud.qcow2"
  sha256sum "${out}/cloud.qcow2" >"${out}/SHA256SUMS" 2>/dev/null || true
  log "qcow2 ✓ at ${out}"
}

# ── Variant: disk-image-rpi4 (RPi 4 SD card, MBR + FAT32 boot) ─────────────
# Plan: docs/plans/wondrous-yawning-anchor.md §3.
# Operator flashes onto SD, Pi boots, agent polls /node_api/claim.
# arm64-only (Pi 4 is arm64; 32-bit Pi support deferred).
build_disk_image_rpi4() {
  if [[ "$ARCH" != "arm64" ]]; then
    log "disk-image-rpi4 is arm64-only — skipping for $ARCH"
    return 0
  fi
  log "Building RPi 4 disk image…"
  local out="${ARCH_OUT}/disk-image-rpi4"
  mkdir -p "${out}"
  KERNEL_INITRD_DIR="${ARCH_OUT}/kernel-initrd" \
    bash "${SCRIPT_DIR}/images/disk-image-rpi4/build-disk-image-rpi4.sh" \
      --output "${out}/powernode-rpi4.img" \
      ${PLATFORM_URL:+--platform-url "$PLATFORM_URL"} \
      ${CA_PEM_FILE:+--ca-pem-file "$CA_PEM_FILE"} \
      ${RPI4_FIRMWARE_DIR:+--firmware-dir "$RPI4_FIRMWARE_DIR"}
  sha256sum "${out}/powernode-rpi4.img" >"${out}/SHA256SUMS" 2>/dev/null || true
  log "disk-image-rpi4 ✓ at ${out}"
}

# ── Variant: disk-image-arm64-uefi (Pi 5 / Ampere / generic UEFI arm64) ────
# A COMPLETE bootable image — identical model to disk-image-amd64-uefi: a UKI
# (kernel+initramfs+cmdline fused via ukify) on a BOOT-labelled ESP at
# /EFI/BOOT/BOOTAA64.EFI, plus an ext4 persist partition. UEFI firmware boots
# the UKI; the initramfs mounts LABEL=BOOT at /boot for the claim-by-ID
# identity.cfg. Needs a real arm64 kernel-initrd, so build it inside an arm64
# environment (native arm64 runner, or a QEMU-emulated arm64 container).
build_disk_image_arm64_uefi() {
  if [[ "$ARCH" != "arm64" ]]; then
    log "disk-image-arm64-uefi is arm64-only — skipping for $ARCH"
    return 0
  fi
  log "Building generic arm64 UEFI disk image…"
  local out="${ARCH_OUT}/disk-image-arm64-uefi"
  mkdir -p "${out}"
  KERNEL_INITRD_DIR="${ARCH_OUT}/kernel-initrd" \
    bash "${SCRIPT_DIR}/images/disk-image-arm64-uefi/build-disk-image-arm64-uefi.sh" \
      --output "${out}/powernode-arm64-uefi.img" \
      ${PLATFORM_URL:+--platform-url "$PLATFORM_URL"} \
      ${CA_PEM_FILE:+--ca-pem-file "$CA_PEM_FILE"}
  sha256sum "${out}/powernode-arm64-uefi.img" >"${out}/SHA256SUMS" 2>/dev/null || true
  log "disk-image-arm64-uefi ✓ at ${out}"
}

# ── Variant: disk-image-amd64-uefi (generic UEFI amd64 — claim-by-ID fleet) ─
# A COMPLETE bootable image (unlike raw/arm64-uefi which only partition): a UKI
# (kernel+initramfs+cmdline fused via ukify) on a BOOT-labelled ESP at
# /EFI/BOOT/BOOTX64.EFI, plus an ext4 persist partition. OVMF boots the UKI;
# the initramfs mounts LABEL=BOOT at /boot for the claim-by-ID identity.cfg.
build_disk_image_amd64_uefi() {
  if [[ "$ARCH" != "amd64" ]]; then
    log "disk-image-amd64-uefi is amd64-only — skipping for $ARCH"
    return 0
  fi
  log "Building generic amd64 UEFI disk image…"
  local out="${ARCH_OUT}/disk-image-amd64-uefi"
  mkdir -p "${out}"
  KERNEL_INITRD_DIR="${ARCH_OUT}/kernel-initrd" \
    bash "${SCRIPT_DIR}/images/disk-image-amd64-uefi/build-disk-image-amd64-uefi.sh" \
      --output "${out}/powernode-amd64-uefi.img" \
      ${PLATFORM_URL:+--platform-url "$PLATFORM_URL"} \
      ${CA_PEM_FILE:+--ca-pem-file "$CA_PEM_FILE"}
  sha256sum "${out}/powernode-amd64-uefi.img" >"${out}/SHA256SUMS" 2>/dev/null || true
  log "disk-image-amd64-uefi ✓ at ${out}"
}

# ── Variant: OCI image (bootc-compatible) ──────────────────────────────────
build_oci() {
  log "Building OCI bootc image…"
  local out="${ARCH_OUT}/oci"
  mkdir -p "${out}"
  if ! command -v buildah >/dev/null 2>&1; then
    log "WARN: buildah not installed — OCI build skipped (install buildah for bootc)"
    return 0
  fi
  buildah bud \
    --platform "linux/${ARCH}" \
    --build-arg "BASE_IMAGE_DIGEST=${BASE_IMAGE_DIGEST}" \
    -t "powernode-bootc:${ARCH}" \
    -f "${SCRIPT_DIR}/images/oci/Containerfile" \
    "${SCRIPT_DIR}/images/oci"
  log "oci ✓ tag=powernode-bootc:${ARCH}"
}

# ── Dispatch ───────────────────────────────────────────────────────────────
log "Starting build (variants: ${VARIANTS})"

IFS=',' read -ra VARIANT_LIST <<<"${VARIANTS}"
for v in "${VARIANT_LIST[@]}"; do
  case "$v" in
    kernel-initrd)            build_kernel_initrd ;;
    raw)                      build_raw ;;
    iso)                      build_iso ;;
    ipxe)                     build_ipxe ;;
    qcow2)                    build_qcow2 ;;
    oci)                      build_oci ;;
    disk-image-rpi4)          build_disk_image_rpi4 ;;
    disk-image-arm64-uefi)    build_disk_image_arm64_uefi ;;
    disk-image-amd64-uefi)    build_disk_image_amd64_uefi ;;
    *)                        log "WARN: unknown variant '$v' — skipped" ;;
  esac
done

# ── Reproducibility manifest ──────────────────────────────────────────────
# Emit a machine-readable build-manifest.json that the M3 reproducibility
# gate diffs between two builds of the same source. Two back-to-back runs
# with identical pins MUST produce byte-identical manifests (modulo git_sha,
# which the gate strips before diffing).
if ! command -v jq >/dev/null 2>&1; then
  log "FATAL: jq is required to emit build-manifest.json (apt install jq)"
  exit 1
fi

artifacts_json="{}"
while IFS= read -r f; do
  rel="${f#${ARCH_OUT}/}"
  sha=$(sha256sum "$f" | awk '{print $1}')
  size=$(stat -c %s "$f")
  artifacts_json=$(jq -n \
    --argjson acc "$artifacts_json" \
    --arg k "$rel" --arg s "$sha" --argjson n "$size" \
    '$acc + {($k): {sha256: $s, size_bytes: $n}}')
done < <(find "${ARCH_OUT}" -type f \
         \( -name 'kernel' -o -name 'initramfs.cpio.zst' \
            -o -name '*.img' -o -name '*.iso' -o -name '*.qcow2' \) \
         | sort)

# OCI image digest (buildah inspect) if the oci variant ran.
oci_digest="null"
if command -v buildah >/dev/null 2>&1 \
   && buildah images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "powernode-bootc:${ARCH}"; then
  d=$(buildah inspect --format '{{.FromImageDigest}}' "powernode-bootc:${ARCH}" 2>/dev/null)
  [[ -n "$d" ]] && oci_digest=$(jq -nc --arg v "$d" '$v')
fi

# fs-verity root hash for the composefs blob (if Stage-2 composer produced one).
fsverity_hash="null"
if [[ -f "${ARCH_OUT}/oci/composefs.blob" ]] && command -v fsverity >/dev/null 2>&1; then
  h=$(fsverity digest "${ARCH_OUT}/oci/composefs.blob" 2>/dev/null | awk '{print $1}')
  [[ -n "$h" ]] && fsverity_hash=$(jq -nc --arg v "$h" '$v')
fi

jq -n \
  --arg arch "${ARCH}" \
  --arg base "${BASE_IMAGE_DIGEST}" \
  --arg apt "${APT_SNAPSHOT:-unknown}" \
  --arg kver "${KERNEL_VERSION:-$(uname -r)}" \
  --arg git "$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)" \
  --arg variants "${VARIANTS}" \
  --argjson artifacts "$artifacts_json" \
  --argjson oci "$oci_digest" \
  --argjson fsverity "$fsverity_hash" \
  '{schema_version: 1,
    arch: $arch,
    base_image_digest: $base,
    apt_snapshot: $apt,
    kernel_version: $kver,
    git_sha: $git,
    variants: ($variants | split(",")),
    artifacts: $artifacts,
    oci_digest: $oci,
    fsverity_root_hash: $fsverity}' \
  >"${ARCH_OUT}/build-manifest.json"

log "Build complete: ${ARCH_OUT} (manifest: build-manifest.json)"
