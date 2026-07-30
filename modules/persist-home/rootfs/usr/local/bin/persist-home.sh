#!/bin/bash
# persist-home.sh — create + own the durable /persist-backed home directory
# that home-pnadmin.mount then bind-mounts onto /home/pnadmin. Runs BEFORE
# that .mount (and before any login) so the bind source always exists and is
# correctly owned.
#
# Why this exists: on a pivot node the root overlay upper is tmpfs (ephemeral —
# see `df /`), so /home/pnadmin is WIPED on every reboot / recompose, taking
# the operator's Claude Code auth (~/.claude), ~/.ssh, tmux-manager session
# configs, shell history and any uncommitted work with it. /persist is a
# durable ext4 partition; backing the home there fixes it.
#
# Lifted from dev-cell's dev-cell-persist-home.sh, which has carried this
# mechanism for the dev cell. Same "durable state belongs on /persist, not the
# tmpfs overlay" pattern as postgres-start.sh, including its o+x
# parent-traversal handling for the agent-owned /persist chain.
set -euo pipefail

if ! mountpoint -q /persist 2>/dev/null; then
  echo "[persist-home] /persist is not a mountpoint — skipping (non-pivot host, home stays on root fs)"
  exit 0
fi

# /persist/home is the shared parent: root:root 0755 so each user can descend
# to its own 0700 home. The powernode agent owns /persist 0700 for its PKI;
# grant traversal-only (o+x, NOT o+r) so a non-root login can reach
# /persist/home/<user>.
chmod o+x /persist 2>/dev/null || true
install -d -m 0755 -o root -g root /persist/home

u=pnadmin
if id "$u" >/dev/null 2>&1; then
  h="/persist/home/$u"
  # Idempotent: only create/own, NEVER delete — existing persisted content
  # (auth, configs, history) must survive across boots.
  install -d -m 0700 -o "$u" -g "$u" "$h"
  install -d -m 0700 -o "$u" -g "$u" "$h/.ssh"

  # The bind TARGET must exist before home-pnadmin.mount binds onto it, and
  # this service is ordered before systemd-tmpfiles-setup.service (which is
  # what normally creates /home + /home/pnadmin from base-os's
  # powernode-home.conf), so create the mountpoint chain here. tmpfiles then
  # re-applies its entries onto the BOUND (persisted) dir, which is what we want.
  install -d -m 0755 -o root -g root /home
  install -d -m 0700 -o "$u" -g "$u" "/home/$u"

  # First-boot skeleton seed: without this the operator lands in a bare home
  # (no .bashrc/.profile → no prompt, PATH quirks, no persistent history).
  # Guarded on .bashrc absence so it NEVER clobbers the operator's own edits.
  if [ ! -e "$h/.bashrc" ] && [ -d /etc/skel ]; then
    cp -a /etc/skel/. "$h/" 2>/dev/null || true
    : > "$h/.bash_history"
    chown -R "$u:$u" "$h"
    echo "[persist-home] seeded /etc/skel into fresh home $h"
  fi

  echo "[persist-home] prepared durable home $h for $u (+ mountpoint /home/$u)"
else
  echo "[persist-home] user $u absent — nothing to prepare"
fi
