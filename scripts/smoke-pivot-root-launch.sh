#!/usr/bin/env bash
# Pivot-root smoke test — qemu-side launcher.
#
# Companion to server/db/seeds/smoke_test_pivot_root.rb. The Ruby driver
# provisions the Federation::Peer + writes the fw-cfg payload locally;
# this bash script streams the payload to a PVE node + launches a
# transient qemu VM + captures serial output.
#
# Expected boot timeline (per powernode.pivot_root_smoke_proven_2026_05_24
# memory key — proven 2026-05-24):
#   t=1.97s — kernel init memory freed
#   t=2.00s — systemd-in-initramfs starts
#   t=3.00s — systemd-networkd brings ens3 up via SLIRP DHCP
#   t=3.60s — ssh-host-keygen.service runs
#   t=5.50s — multi-user.target reached
#   t=6.90s — sshd listens on 0.0.0.0:22
#   t=6.94s — powernode-federation-accept.service runs the accept handshake
#   t=7.00s — agent receives node_enrollment block, enrolls, cert on /persist
#   t=7.10s — powernode-agent.service starts; service.bootstrap fast-paths
#             via existing cert + enters reconcile loop
#   ~30s   — reconcile pulls system-base + base-os-ubuntu-noble blobs
#   ~60s   — agent prepares /sysroot overlay + switch_roots
#   ~90s   — system-base's systemd takes over post-pivot
#
# Usage:
#   bash smoke-pivot-root-launch.sh \
#     --pve-node dna \
#     --fwcfg-dir /tmp/pn-smoke-fwcfg \
#     --peer-id <federation-peer-uuid>
#
# Operates via the admin@PVE → sudo ssh root@localhost escalation
# pattern (see powernode.pve_admin_escalation in memory).

set -euo pipefail

PVE_NODE=""
FWCFG_DIR=""
PEER_ID=""
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-120}"
KERNEL_PATH="${KERNEL_PATH:-/var/lib/vz/template/iso/powernode-vmlinuz}"
INITRD_PATH="${INITRD_PATH:-/var/lib/vz/template/iso/powernode-initramfs.img}"
MEMORY_MB="${MEMORY_MB:-4096}"
VCPUS="${VCPUS:-2}"

usage() {
  cat <<USAGE
Pivot-root smoke launcher.

Required:
  --pve-node <name>      Target PVE node hostname (e.g., dna, rna)
  --fwcfg-dir <path>     Local dir containing fw-cfg key files
  --peer-id <uuid>       Federation::Peer UUID for log correlation

Optional env:
  TIMEOUT_SECONDS=120    Serial capture duration before SIGTERM to qemu
  KERNEL_PATH=...        Kernel artifact on PVE (default /var/lib/vz/...)
  INITRD_PATH=...        Initramfs on PVE (default same dir)
  MEMORY_MB=4096         VM memory
  VCPUS=2                VM vCPUs

Output:
  Serial console capture to /tmp/qemu-smoke-<peer-id>.log on the PVE node.
  Last 80 lines streamed back to operator stdout for quick triage.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pve-node)   PVE_NODE="$2"; shift 2 ;;
    --fwcfg-dir)  FWCFG_DIR="$2"; shift 2 ;;
    --peer-id)    PEER_ID="$2"; shift 2 ;;
    --help|-h)    usage; exit 0 ;;
    *)            echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -z "$PVE_NODE" ]]  && { echo "ERROR: --pve-node required" >&2; usage; exit 1; }
[[ -z "$FWCFG_DIR" ]] && { echo "ERROR: --fwcfg-dir required" >&2; usage; exit 1; }
[[ -z "$PEER_ID" ]]   && { echo "ERROR: --peer-id required" >&2; usage; exit 1; }
[[ ! -d "$FWCFG_DIR" ]] && { echo "ERROR: fw-cfg dir $FWCFG_DIR not present" >&2; exit 1; }

PVE_HOST="admin@${PVE_NODE}.ipnode.net"
REMOTE_FWCFG_DIR="/tmp/pn-smoke-fwcfg"
SERIAL_LOG="/tmp/qemu-smoke-${PEER_ID}.log"

echo "===== Pivot-root smoke launcher ====="
echo "  PVE node:     $PVE_NODE"
echo "  fw-cfg src:   $FWCFG_DIR"
echo "  peer-id:      $PEER_ID"
echo "  serial log:   $PVE_HOST:$SERIAL_LOG"
echo "  capture:      ${TIMEOUT_SECONDS}s"
echo ""

# --- Phase 1: stream fw-cfg to PVE via tar pipe (no plaintext on dev fs) -
echo "[1/3] Streaming fw-cfg payload to $PVE_HOST..."
tar -C "$(dirname "$FWCFG_DIR")" -cf - "$(basename "$FWCFG_DIR")" \
  | ssh -o BatchMode=yes "$PVE_HOST" "cat > /tmp/pn-smoke-fwcfg.tar"
ssh -o BatchMode=yes "$PVE_HOST" \
  "sudo ssh -o StrictHostKeyChecking=accept-new root@localhost '
    rm -rf $REMOTE_FWCFG_DIR
    tar -C /tmp -xf /tmp/pn-smoke-fwcfg.tar
    if [ \"$REMOTE_FWCFG_DIR\" != /tmp/\$(basename $FWCFG_DIR) ]; then
      mv /tmp/\$(basename $FWCFG_DIR) $REMOTE_FWCFG_DIR
    fi
    rm /tmp/pn-smoke-fwcfg.tar
    chmod 0700 $REMOTE_FWCFG_DIR
    chmod 0600 $REMOTE_FWCFG_DIR/*
  '"
echo "  ✓ staged"

# --- Phase 2: build + ship the qemu launcher script ----------------------
LAUNCHER_TMP=$(mktemp)
cat > "$LAUNCHER_TMP" <<'QEMU_SCRIPT'
#!/bin/bash
set -e
FWCFG_DIR="$1"
SERIAL_LOG="$2"
TIMEOUT_SECONDS="$3"
KERNEL_PATH="$4"
INITRD_PATH="$5"
MEMORY_MB="$6"
VCPUS="$7"

# Build -fw_cfg args for each key file in the dir.
FW_CFG_ARGS=()
for key in instance_uuid platform_url parent_url acceptance_token \
           spawn_mode parent_peer_id contract_version; do
  path="$FWCFG_DIR/$key"
  if [ -f "$path" ]; then
    FW_CFG_ARGS+=(-fw_cfg "name=opt/com.powernode/$key,file=$path")
  fi
done

echo "[qemu] launching with ${#FW_CFG_ARGS[@]} fw-cfg entries (capture: ${TIMEOUT_SECONDS}s)"
timeout "$TIMEOUT_SECONDS" qemu-system-x86_64 \
  -kernel "$KERNEL_PATH" \
  -initrd "$INITRD_PATH" \
  -append 'console=ttyS0,115200 powernode.boot=1 ip=dhcp rd.shell rd.debug' \
  "${FW_CFG_ARGS[@]}" \
  -serial mon:stdio \
  -nographic \
  -m "$MEMORY_MB" -smp "$VCPUS" \
  -enable-kvm \
  -nic user \
  -no-reboot \
  </dev/null > "$SERIAL_LOG" 2>&1 || true

echo "[qemu] capture exited"
echo "[serial-tail] last 80 lines:"
tail -80 "$SERIAL_LOG"
QEMU_SCRIPT
chmod +x "$LAUNCHER_TMP"

scp -B "$LAUNCHER_TMP" "$PVE_HOST:/tmp/qemu-smoke-launcher.sh" > /dev/null
rm -f "$LAUNCHER_TMP"

# --- Phase 3: invoke launcher under root via the escalation path ---------
echo "[2/3] Invoking qemu launcher on $PVE_HOST..."
ssh -o BatchMode=yes "$PVE_HOST" \
  "sudo ssh root@localhost 'bash /tmp/qemu-smoke-launcher.sh \
    $REMOTE_FWCFG_DIR \
    $SERIAL_LOG \
    $TIMEOUT_SECONDS \
    $KERNEL_PATH \
    $INITRD_PATH \
    $MEMORY_MB \
    $VCPUS'"

echo ""
echo "[3/3] Done. Serial capture is at $PVE_HOST:$SERIAL_LOG"
echo "       For full log: ssh $PVE_HOST 'sudo ssh root@localhost cat $SERIAL_LOG'"
