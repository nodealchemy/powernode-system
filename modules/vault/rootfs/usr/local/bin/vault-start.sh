#!/bin/bash
# vault-start.sh — prepare durable storage, then hand off to the Vault server.
#
# Runs as root (the manifest's service user) purely to create and own the
# storage directory, then drops to the unprivileged `vault` account before
# exec'ing the server.
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

DEFAULT_CONFIG=/etc/vault.d/vault.hcl
PERSIST_CONFIG=/persist/etc/vault.d/vault.hcl
DATA_DIR=/persist/var/lib/vault/data
RUN_USER=vault

log() { echo "[vault-start] $*"; }

# /persist must be a real MOUNTPOINT before we write into it.
#
# `findmnt --target` is the wrong test and was the first version of this guard:
# it walks UP to the containing mount, so it returns 0 for any path that merely
# exists — including one sitting on the overlay's writable upper because the
# persist mount lost a race. That inert check would have let Vault initialise
# onto volatile storage and lose the entire store at the next reboot, presenting
# as data loss rather than as the ordering bug it is. --mountpoint tests the
# path ITSELF and returns non-zero when it is not a mount.
if ! findmnt -rn --mountpoint /persist >/dev/null 2>&1; then
  log "FATAL: /persist is not a mountpoint; refusing to place Vault storage on volatile overlay"
  exit 1
fi

# Operator edits survive here, and ONLY here. protected_spec keeps the shipped
# copy safe from a hot module refresh, but the live root's upper is a scratch
# tmpfs, so an in-place edit to /etc/vault.d/vault.hcl is lost at the next full
# reboot. A config placed under /persist is the durable one and wins.
if [[ -r "$PERSIST_CONFIG" ]]; then
  CONFIG="$PERSIST_CONFIG"
  log "using operator config $PERSIST_CONFIG"
elif [[ -r "$DEFAULT_CONFIG" ]]; then
  CONFIG="$DEFAULT_CONFIG"
  log "using shipped default config $DEFAULT_CONFIG (loopback, sealed)"
else
  log "FATAL: no readable config at $PERSIST_CONFIG or $DEFAULT_CONFIG"
  exit 1
fi

if [[ ! -x /usr/local/bin/vault ]]; then
  log "FATAL: /usr/local/bin/vault missing or not executable"
  exit 1
fi

mkdir -p "$DATA_DIR"
chown -R "${RUN_USER}:${RUN_USER}" /persist/var/lib/vault
# 0700: file storage holds the sealed keyring. Vault itself warns on permissive
# storage, and group/other have no business reading it.
chmod 0700 /persist/var/lib/vault "$DATA_DIR"

log "starting Vault (sealed; run 'vault operator init' / 'unseal' as operator)"

# setpriv, NOT runuser.
#
# The agent grants security.capabilities as CapabilityBoundingSet= +
# AmbientCapabilities= on the unit, which reaches THIS root wrapper — but a
# 0 -> non-0 uid transition clears the permitted, effective and ambient sets.
# Verified on dev-cell: `runuser -u nobody -- grep Cap /proc/self/status` yields
# CapEff/CapAmb = 0. Vault's mlockall() is FATAL when disable_mlock is false, so
# dropping via runuser would make the service exit 1 on every start.
# setpriv re-raises CAP_IPC_LOCK into the inheritable + ambient sets across the
# drop (CAP_SETPCAP in the manifest is what permits raising the inheritable bit).
exec setpriv --reuid="$RUN_USER" --regid="$RUN_USER" --init-groups \
     --inh-caps=+ipc_lock --ambient-caps=+ipc_lock -- \
     /usr/local/bin/vault server -config="$CONFIG"
