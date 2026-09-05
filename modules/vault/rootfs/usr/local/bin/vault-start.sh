#!/bin/bash
# vault-start.sh — prepare durable storage, then hand off to the Vault server.
#
# Runs as root (the manifest's service user) purely to create and own the
# storage directory, then drops to the unprivileged `vault` account via runuser
# before exec'ing the server. Mirrors redis-start.sh / the postgres-primary
# wrapper; see the capabilities comment in the module manifest for why each
# capability is needed under RootDirectory=/sysroot.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO:
#   - it does not run `vault operator init`
#   - it does not unseal
#   - it does not read, write, generate or echo any token or unseal key
# Vault comes up SEALED and an operator initialises it by hand. A start script
# that auto-initialised would have to put the resulting root token and unseal
# keys somewhere, and every available "somewhere" on this node is a file, a log
# or an environment variable.

set -euo pipefail

CONFIG=/etc/vault.d/vault.hcl
DATA_DIR=/persist/var/lib/vault/data
RUN_USER=vault

log() { echo "[vault-start] $*"; }

if [[ ! -r "$CONFIG" ]]; then
  log "FATAL: $CONFIG missing or unreadable"
  exit 1
fi

# /persist must be a real mount before we write into it. Without this check a
# boot that raced the persist mount would silently create the storage dir on
# the overlay's writable upper layer, Vault would initialise happily, and the
# entire store would disappear at the next reboot — presenting as data loss
# rather than as the ordering bug it is.
if ! findmnt -rn --target /persist >/dev/null 2>&1; then
  log "FATAL: /persist is not mounted; refusing to place Vault storage on volatile overlay"
  exit 1
fi

mkdir -p "$DATA_DIR"
chown -R "${RUN_USER}:${RUN_USER}" /persist/var/lib/vault
# 0700: Vault's file storage holds the sealed keyring. Group/other have no
# business reading it, and Vault itself warns on permissive storage.
chmod 0700 /persist/var/lib/vault "$DATA_DIR"

# Refuse to start on storage anything but the vault user can read. This is the
# check that catches a hand-fixed directory left at 0755 after an operator
# debugged something as root.
mode=$(stat -c '%a' "$DATA_DIR")
if [[ "$mode" != "700" ]]; then
  log "FATAL: $DATA_DIR is mode $mode, expected 700"
  exit 1
fi

if [[ ! -x /usr/local/bin/vault ]]; then
  log "FATAL: /usr/local/bin/vault missing or not executable"
  exit 1
fi

log "starting Vault (sealed; run 'vault operator init' / 'unseal' as operator)"
exec runuser -u "$RUN_USER" -- /usr/local/bin/vault server -config="$CONFIG"
