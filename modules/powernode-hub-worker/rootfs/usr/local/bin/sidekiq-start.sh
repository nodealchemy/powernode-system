#!/bin/bash
# sidekiq-start.sh — wait for hub-backend's secrets + vendor + exec sidekiq.
#
# The worker module ships /opt/powernode/worker/ (its own Gemfile),
# but it depends on the secrets that hub-backend's rails-start.sh
# generates on first boot — RAILS_ENV, DATABASE_URL, REDIS_URL,
# encryption keys, etc.
#
# Worker has its OWN Gemfile.lock so it needs its OWN vendor/bundle
# (rails sidekiq + worker-specific gems differ from the backend's
# server Gemfile).
#
# IMP-94977647c24c: reads hub-backend's STATE_DIR directly instead of
# the old /etc/powernode/backend-default.conf symlink — hub-backend's
# rails service dropped root and can no longer publish there (root-owned
# parent). STATE_DIR is now a CROSS-MODULE CONTRACT between these two
# modules (same mountpoint-based resolution both sides must agree on),
# not a hub-backend-private detail. This is safe TODAY: sidekiq reads
# $STATE_DIR/backend-default.conf AS ROOT, and STATE_DIR is now
# 0700-mode, owned by powernode-rails (not root) — root ignores Unix
# permission bits entirely, so that mode/ownership is no obstacle to
# THIS process. Part B (dropping hub-worker off root too — deferred, see
# modules/.schema/root-user-exceptions.yml: unmet polkit prerequisite for
# the sandboxed stdio-MCP systemd-run it needs) LOSES this read the
# moment it lands: a non-root worker user, not in the powernode-rails
# group, could no longer even traverse into STATE_DIR to reach this
# file. Whoever does part B needs a supplementary-group grant (mirroring
# how rails itself joins the traefik group for the ingress dirs) or an
# equivalent, not just a manifest `user:` change.
set -euo pipefail

# Derive STATE_DIR with the EXACT same skeleton hub-backend's own
# rails-setup.sh/rails-start.sh use (byte-identical block, checked by
# spec/scripts/rails_setup_root_prep_spec.rb) — this is the cross-module
# contract's enforcement mechanism: two scripts computing the same path a
# different way is exactly how the contract silently drifts.
if mountpoint -q /persist 2>/dev/null; then
  STATE_DIR=/persist/powernode-rails
else
  STATE_DIR=/var/lib/powernode-rails
fi
SECRETS_FILE="$STATE_DIR/backend-default.conf"
WORKER_DIR=/opt/powernode/worker

# Wait for hub-backend's rails-start.sh to publish secrets (it runs
# in the same overlay so the file becomes visible cross-service).
echo "[sidekiq-start] Waiting for $SECRETS_FILE..."
for i in $(seq 1 60); do
  if [ -f "$SECRETS_FILE" ]; then
    echo "[sidekiq-start] secrets ready"
    break
  fi
  sleep 4
done
if [ ! -f "$SECRETS_FILE" ]; then
  echo "[sidekiq-start] FATAL: $SECRETS_FILE never appeared — hub-backend's rails-start failed?"
  exit 1
fi

set -a
. "$SECRETS_FILE"
set +a

# WORKER_ID / BACKEND_API_URL / WORKER_TLS_VERIFY / WORKER_PKI_DIR / REDIS_URL are
# supplied by the module manifest env (systemd Environment=); JWT_SECRET_KEY +
# encryption keys come from the shared secrets file sourced above.

cd "$WORKER_DIR"

# Worker's own bundle (independent from backend's), installed offline
# from the module-vendored cache — managed children have no rubygems
# egress. The worker Gemfile has no extension path gems, so its lock is
# self-consistent: `bundle install --local` installs from worker/vendor/
# cache and compiles native extensions on-instance against runtime-ruby.
if [ ! -d vendor/bundle ] || [ -z "$(ls -A vendor/bundle 2>/dev/null)" ]; then
  echo "[sidekiq-start] Installing worker gems from vendored cache (offline)"
  /usr/local/bin/bundle config set --local path 'vendor/bundle'
  /usr/local/bin/bundle config set --local without 'development:test'
  /usr/local/bin/bundle install --local --jobs 4
fi

echo "[sidekiq-start] Starting sidekiq"
# -r ./config/application.rb is REQUIRED: without it, Sidekiq's CLI assumes a Rails
# app and does `require 'rails'`, which crash-loops the lean worker (its Gemfile has
# no `rails` gem — only sidekiq/activesupport/actionmailer/etc.). application.rb is
# the worker's own boot file (loads sidekiq + sidekiq-scheduler, registers schedules).
exec /usr/local/bin/bundle exec sidekiq -r ./config/application.rb -C config/sidekiq.yml
