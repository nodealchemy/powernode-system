#!/bin/bash
# dev-cell-ssh-hostkeys.sh — give the cell a STABLE SSH host identity across
# reboot/recompose. The root overlay upper is ephemeral tmpfs (see
# dev-cell-persist-home.sh), so /etc/ssh/ssh_host_*_key is regenerated on every
# boot → the operator's client hits "REMOTE HOST IDENTIFICATION HAS CHANGED"
# each time and must scrub known_hosts. Persist the host keys on the durable
# /persist partition and restore them into /etc/ssh BEFORE sshd reads them (this
# unit is ordered Before=ssh.service/ssh.socket, at local-fs.target, well ahead
# of sockets.target). Keys are generated directly in /persist on first boot
# (idempotent), so we never depend on base-os's own keygen timing.
set -euo pipefail

if ! mountpoint -q /persist 2>/dev/null; then
  echo "[ssh-hostkeys] /persist not a mountpoint — skipping (non-pivot host, host keys stay ephemeral)"
  exit 0
fi
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "[ssh-hostkeys] ssh-keygen absent — skipping (nothing to persist)"
  exit 0
fi

PDIR=/persist/etc/ssh
install -d -m 0755 -o root -g root /persist/etc
install -d -m 0755 -o root -g root "$PDIR"

# Generate any missing host-key type directly in the persisted dir (idempotent:
# first boot creates, later boots reuse). ssh-keygen writes both <f> and <f>.pub.
for t in rsa ecdsa ed25519; do
  f="$PDIR/ssh_host_${t}_key"
  if [ ! -s "$f" ]; then
    rm -f "$f" "$f.pub"
    ssh-keygen -q -t "$t" -f "$f" -N "" -C "dev-cell" </dev/null
    echo "[ssh-hostkeys] generated persisted $t host key"
  fi
done

# Restore the persisted keys into /etc/ssh so sshd serves the STABLE identity.
install -d -m 0755 /etc/ssh
for f in "$PDIR"/ssh_host_*_key; do
  [ -e "$f" ] || continue
  cp -a "$f" "$f.pub" /etc/ssh/ 2>/dev/null || true
done
chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
echo "[ssh-hostkeys] restored persisted SSH host keys into /etc/ssh"
