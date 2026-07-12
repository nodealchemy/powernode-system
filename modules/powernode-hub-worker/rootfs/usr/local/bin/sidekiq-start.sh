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
set -euo pipefail

SECRETS_FILE=/etc/powernode/backend-default.conf
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
