#!/bin/bash
# worker-web-start.sh — wait for hub-backend's secrets + the worker bundle,
# then exec the worker HTTP API.
#
# Despite the "web" in the name this is NOT just the /sidekiq dashboard: it is
# the whole worker HTTP API. config.ru maps /api/v1 -> JobsController, which is
# where embeddings and the LLM proxy live. The backend's WorkerTransport targets
# it at Rails.application.config.worker_url (WORKER_URL, default
# http://localhost:4567).
#
# Without this service the platform can still SEARCH embeddings already at rest
# but cannot GENERATE a query embedding, so semantic search and embed-on-write
# fail while plain SQL lookups (query_learnings) keep working — a failure mode
# that reads as "mostly healthy". Historically it ran only on the dev box as a
# hand-managed systemd unit (scripts/systemd/powernode-worker-web.sh), which is
# why it was missing from the module set entirely.
set -euo pipefail

SECRETS_FILE=/etc/powernode/backend-default.conf
WORKER_DIR=/opt/powernode/worker

WORKER_WEB_HOST="${SIDEKIQ_WEB_HOST:-127.0.0.1}"
WORKER_WEB_PORT="${SIDEKIQ_WEB_PORT:-4567}"
WORKER_WEB_THREADS="${WORKER_WEB_THREADS:-16}"

# Same handshake as sidekiq-start.sh: hub-backend's rails-start.sh publishes the
# shared secrets file on first boot.
echo "[worker-web-start] Waiting for $SECRETS_FILE..."
for _ in $(seq 1 60); do
  if [ -f "$SECRETS_FILE" ]; then
    echo "[worker-web-start] secrets ready"
    break
  fi
  sleep 4
done
if [ ! -f "$SECRETS_FILE" ]; then
  echo "[worker-web-start] FATAL: $SECRETS_FILE never appeared — hub-backend's rails-start failed?"
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$SECRETS_FILE"
set +a

cd "$WORKER_DIR"

# The worker bundle is installed ONCE by sidekiq-start.sh (same module; the
# manifest orders us after it via dependencies.start_before). Deliberately do
# NOT run `bundle install` here — two concurrent installs into the same
# vendor/bundle race and corrupt each other.
echo "[worker-web-start] Waiting for worker bundle (installed by sidekiq-start.sh)..."
for _ in $(seq 1 150); do
  if [ -d vendor/bundle ] && [ -n "$(ls -A vendor/bundle 2>/dev/null)" ]; then
    break
  fi
  sleep 4
done
if [ ! -d vendor/bundle ] || [ -z "$(ls -A vendor/bundle 2>/dev/null)" ]; then
  echo "[worker-web-start] FATAL: worker bundle never appeared — is the sidekiq service running?"
  exit 1
fi

# config.ru line 21 does File.read('.session.key') unconditionally at LOAD time,
# so an absent file is a hard boot failure (Errno::ENOENT), not a degraded mode.
# The key is a real secret and is deliberately not shipped in the module —
# scripts/security-cleanup.sh scrubs it from the tree — so generate it on first
# boot, the same way rails-start.sh publishes the backend secrets file. It only
# signs /sidekiq dashboard cookies; regenerating it invalidates open dashboard
# sessions and nothing else.
if [ ! -s .session.key ]; then
  echo "[worker-web-start] Generating .session.key"
  (
    umask 077
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 64 > .session.key
    else
      head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' > .session.key
    fi
  )
fi

echo "[worker-web-start] Starting worker HTTP API on ${WORKER_WEB_HOST}:${WORKER_WEB_PORT}"
exec /usr/local/bin/bundle exec rackup \
  -s puma \
  -o "${WORKER_WEB_HOST}" \
  -p "${WORKER_WEB_PORT}" \
  -O "Threads=0:${WORKER_WEB_THREADS}" \
  config.ru
