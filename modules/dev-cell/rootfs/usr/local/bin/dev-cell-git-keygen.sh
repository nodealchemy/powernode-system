#!/bin/bash
# dev-cell-git-keygen.sh — generate the operator's PERSISTENT git SSH key ON
# THE DEV-CELL (private half NEVER leaves this box, is never transmitted,
# echoed, or logged) and pin git.powernode.net's host key. Runs as pnadmin at
# first boot so the key is ready before the operator logs in.
#
# Design (operator-owned git creds, per campaign #40): the private key is
# generated locally with ssh-keygen and stays in the operator's persisted
# ~/.ssh (on /persist via home-pnadmin.mount). Only the PUBLIC key is ever
# surfaced — printed to the journal + shown by `dev-cell-clone`. The operator
# registers that PUBLIC key with Gitea himself (his own Gitea access), the same
# way he'd set up any dev box; nothing here handles Gitea API tokens or private
# key material. (A fully zero-touch auto-registration would need either a
# platform-minted key delivered to the cell — which we deliberately avoid — or
# a new node_api register-public-key endpoint.)
set -euo pipefail

KEY="$HOME/.ssh/id_ed25519"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
GIT_HOST="${DEV_CELL_GIT_HOST:-git.powernode.net}"

umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$KEY" ]; then
  # -N '' : no passphrase (unattended interactive dev box). The private key is
  # protected by file perms (0600) on the operator's own persisted home, never
  # transmitted anywhere.
  ssh-keygen -t ed25519 -N '' -C "pnadmin@dev-cell" -f "$KEY" >/dev/null
  echo "[git-keygen] generated a new ed25519 git key (private stays local, 0600)"
else
  echo "[git-keygen] git key already present — leaving it"
fi

# Pin the Gitea host key (TOFU on first setup — the cell reaches .net:22). Only
# added if not already pinned, so a later host-key change isn't silently masked.
if [ -n "$GIT_HOST" ] && ! ssh-keygen -F "$GIT_HOST" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
  if ssh-keyscan -T 8 "$GIT_HOST" >>"$KNOWN_HOSTS" 2>/dev/null; then
    echo "[git-keygen] pinned $GIT_HOST host key in known_hosts"
  else
    echo "[git-keygen] WARN: could not ssh-keyscan $GIT_HOST (network?) — clone will prompt until reachable"
  fi
fi

# Surface the PUBLIC key so the operator can register it with Gitea. Safe to
# print — it is the public half only.
echo "[git-keygen] register this PUBLIC key with Gitea (Settings -> SSH Keys), then run 'dev-cell-clone':"
echo "-----8<----- PUBLIC KEY -----8<-----"
cat "$KEY.pub"
echo "-----8<----------------------8<-----"
