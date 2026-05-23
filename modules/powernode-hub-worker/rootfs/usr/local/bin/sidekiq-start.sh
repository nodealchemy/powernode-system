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

cd "$WORKER_DIR"

# Worker's own bundle (independent from backend's).
if [ ! -d vendor/bundle ] || [ -z "$(ls -A vendor/bundle 2>/dev/null)" ]; then
  echo "[sidekiq-start] Vendoring worker gems (first boot)"
  /usr/bin/bundle config set --local deployment 'true'
  /usr/bin/bundle config set --local without 'development:test'
  /usr/bin/bundle install --jobs 4 --retry 2
fi

echo "[sidekiq-start] Starting sidekiq"
exec /usr/bin/bundle exec sidekiq -C config/sidekiq.yml
