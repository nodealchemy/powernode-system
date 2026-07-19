#!/bin/bash
# dev-cell-persist-home.sh — create + own the durable /persist-backed home
# directory that home-pnadmin.mount then bind-mounts onto /home/pnadmin.
# Runs BEFORE that .mount (and before any login) so the bind source always
# exists and is correctly owned.
#
# Why this exists: on a pivot cell the root overlay upper is tmpfs (512M,
# ephemeral — see `df /`), so /home/pnadmin is WIPED on every reboot /
# recompose, taking the operator's Claude Code auth (~/.claude), cloned
# source, ~/.ssh, shell history and any uncommitted work with it. That makes
# the cell unusable as a dev box. /persist is a durable ext4 partition;
# backing the home there fixes it. Mirrors postgres-primary/postgres-start.sh's
# identical "durable state belongs on /persist, not the tmpfs overlay" pattern
# (and its o+x parent-traversal handling for the agent-owned /persist chain).
set -euo pipefail

if ! mountpoint -q /persist 2>/dev/null; then
  echo "[persist-home] /persist is not a mountpoint — skipping (non-pivot host, home stays on root fs)"
  exit 0
fi

# /persist/home is the shared parent: root:root 0755 so each user can descend
# to its own 0700 home. The powernode agent owns /persist and /persist/var
# 0700 for its PKI; grant traversal-only (o+x, NOT o+r) on /persist so a
# non-root login can reach /persist/home/<user> — same technique
# postgres-start.sh uses to let the postgres uid reach its PGDATA.
chmod o+x /persist 2>/dev/null || true
install -d -m 0755 -o root -g root /persist/home

u=pnadmin
if id "$u" >/dev/null 2>&1; then
  h="/persist/home/$u"
  # Idempotent: only create/own, NEVER delete — existing persisted content
  # (auth, clones, history) must survive across boots.
  install -d -m 0700 -o "$u" -g "$u" "$h"
  # Seed the standard subdir base-os's powernode-home.conf tmpfiles + the
  # agent's authorized_keys reconcile expect, first-boot only.
  install -d -m 0700 -o "$u" -g "$u" "$h/.ssh"

  # The bind TARGET must exist before home-pnadmin.mount binds onto it — and
  # this service is ordered Before=systemd-tmpfiles-setup.service (which is
  # what normally creates /home + /home/pnadmin from base-os's
  # powernode-home.conf), so create the mountpoint chain here. tmpfiles then
  # re-applies its `d /home/pnadmin 0700` / `.ssh` entries onto the BOUND
  # (persisted) dir, which is exactly what we want.
  install -d -m 0755 -o root -g root /home
  install -d -m 0700 -o "$u" -g "$u" "/home/$u"

  echo "[persist-home] prepared durable home $h for $u (+ mountpoint /home/$u)"
else
  echo "[persist-home] user $u absent — nothing to prepare"
fi
