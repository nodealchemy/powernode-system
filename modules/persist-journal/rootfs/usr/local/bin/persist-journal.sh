#!/bin/bash
# persist-journal.sh — create + own the durable /persist-backed journal
# directory that var-log-journal.mount then bind-mounts onto /var/log/journal.
# Runs BEFORE that .mount and before systemd-journal-flush.service, so the bind
# source exists and is correctly owned at the moment journald migrates its
# runtime journal onto disk.
#
# Why this exists: on a pivot node the root overlay upper is tmpfs (ephemeral —
# see `df /`), so /var/log/journal cannot survive a boot, and journald's
# Storage=auto silently falls back to the volatile /run/log/journal. The
# consequence is that a node which fails to come up takes the evidence of WHY
# with it: after a recovery reset the previous boot's logs simply do not exist.
# That is not hypothetical — ops-hub's soft-recompose attempt on 2026-08-10 left
# no userspace for seven minutes, and the recovery destroyed every log of the
# failure window (docs/operations/ops-hub-soft-recompose-runbook.md).
#
# Same "durable state belongs on /persist, not the tmpfs overlay" pattern as
# persist-home.sh and postgres-start.sh, including the o+x parent-traversal
# handling for the agent-owned /persist chain.
set -euo pipefail

if ! mountpoint -q /persist 2>/dev/null; then
  echo "[persist-journal] /persist is not a mountpoint — skipping (non-pivot host, journal stays where it is)"
  exit 0
fi

# The powernode agent owns /persist 0700 for its PKI. journald itself runs as
# root and does not need this, but members of the systemd-journal/adm groups do
# in order to read the journal as a non-root operator — grant traversal only
# (o+x, NOT o+r), exactly as persist-home does.
chmod o+x /persist 2>/dev/null || true
install -d -m 0755 -o root -g root /persist/var /persist/var/log

# 2755 root:systemd-journal is the ownership systemd itself applies to
# /var/log/journal; journald refuses to use a directory it does not trust.
# Fall back to root:root when the group is absent (it ships with systemd, so
# this is belt-and-braces for a stripped userland).
if getent group systemd-journal >/dev/null 2>&1; then
  install -d -m 2755 -o root -g systemd-journal /persist/var/log/journal
else
  install -d -m 2755 -o root -g root /persist/var/log/journal
  echo "[persist-journal] systemd-journal group absent — created journal dir root:root"
fi

# The bind TARGET must exist before var-log-journal.mount binds onto it. This
# service is ordered before systemd-tmpfiles-setup.service, which is what would
# otherwise create /var/log, so create the chain here.
install -d -m 0755 -o root -g root /var/log
install -d -m 2755 -o root -g root /var/log/journal

echo "[persist-journal] prepared durable journal /persist/var/log/journal (+ mountpoint /var/log/journal)"
