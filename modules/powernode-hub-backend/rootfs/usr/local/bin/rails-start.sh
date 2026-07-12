#!/bin/bash
# rails-start.sh — first-boot Rails bootstrap + exec puma.
#
# On a fresh ops2-style spawn the module-mounted /opt/powernode/server
# tree is read-only (erofs lower); the overlay's writable upper holds
# any first-boot mutations. This wrapper handles everything Rails
# needs before puma can serve:
#   1. Generate Rails secrets (secret_key_base + AR encryption keys)
#      — stored in the durable STATE_DIR (/persist when mounted) so
#      subsequent boots AND reboots reuse them; /etc/powernode keeps
#      symlinks for consumers (hub-worker sources the same file).
#   2. Wait for postgres (sibling module on the same instance) to be
#      reachable on localhost:5432.
#   3. Create the powernode role + powernode_production database via
#      psql (as the postgres superuser; trust auth from initdb).
#   4. Vendor gems via bundle install --deployment — first-boot only,
#      slow (~5min) but cached for restarts.
#   5. db:migrate + first-admin bootstrap (bootstrap-first-admin.rb,
#      headless setup-wizard equivalent) + db:seed (idempotent — Rails
#      skips already-applied migrations + seeds check find_or_create).
#   6. exec puma.
#
# The manifest sets user: root on this service so the wrapper can
# mkdir /etc/powernode + chown things. Puma itself runs as root for
# the duration (acceptable for the dogfood; production hardening
# would drop to a dedicated 'powernode' OS user via Puma config).
set -euo pipefail

RAILS_DIR=/opt/powernode/server

# --- Durable state root (marker + generated secrets) ---
# The pivot-boot root overlay upper is EPHEMERAL: anything written only under
# /etc or /var is lost on reboot. That re-ran the "first boot" migrate+seed on
# every boot (the marker vanished) and — now that postgres-primary keeps PGDATA
# under /persist — would regenerate SECRET_KEY_BASE + the AR encryption keys
# against a database that still holds ciphertext from the previous keys. Same
# idiom as postgres-start.sh: prefer /persist when it is a mountpoint (pivot
# cells), fall back to the historical location so non-pivot hosts keep their
# current behavior.
if mountpoint -q /persist 2>/dev/null; then
  STATE_DIR=/persist/powernode-rails
else
  STATE_DIR=/var/lib/powernode-rails
fi
mkdir -p "$STATE_DIR" /etc/powernode
chmod 700 "$STATE_DIR"

SECRETS_FILE=$STATE_DIR/backend-default.conf
ADMIN_CREDS=$STATE_DIR/admin-credentials.json

# Migrate secrets a pre-STATE_DIR revision left at the old /etc paths
# (persistent-root hosts only; on pivot cells /etc is empty after reboot).
for f in backend-default.conf admin-credentials.json; do
  if [ -f "/etc/powernode/$f" ] && [ ! -L "/etc/powernode/$f" ] && [ ! -f "$STATE_DIR/$f" ]; then
    mv "/etc/powernode/$f" "$STATE_DIR/$f"
  fi
done

# Stable consumer paths: sidekiq-start.sh (hub-worker) sources
# /etc/powernode/backend-default.conf — keep both /etc names as symlinks into
# the durable store. `-f` follows symlinks, so the worker's wait loop still
# works (a dangling link reads as absent until the target is written).
ln -sfn "$SECRETS_FILE" /etc/powernode/backend-default.conf
ln -sfn "$ADMIN_CREDS" /etc/powernode/admin-credentials.json

# --- Derive service hosts (loopback by default for the all-in-one image) ---
# postgres + redis are sibling modules co-located on this instance, so
# localhost is the correct DEFAULT for the single-appliance topology. A
# split/distributed fleet injects POWERNODE_DB_HOST / POWERNODE_REDIS_HOST
# (via this module's systemd environment) to point the hub at an external
# postgres/redis WITHOUT rebuilding the image. Auth is unchanged (passwordless
# trust); serving a remote DB additionally requires opening the server side
# (postgres-primary listen_addresses / pg_hba), out of scope here.
DB_HOST=${POWERNODE_DB_HOST:-localhost}
REDIS_HOST=${POWERNODE_REDIS_HOST:-localhost}

# --- Generate secrets if missing (first-boot only) ---
# The initial admin credential is NOT generated here anymore: it is created by
# bootstrap-first-admin.rb (policy-validated password) during the first-boot
# migrate+seed sequence below, and written to $ADMIN_CREDS.
if [ ! -f "$SECRETS_FILE" ]; then
  echo "[rails-start] Generating Rails secrets..."
  SKB=$(openssl rand -hex 64)
  ARP=$(openssl rand -hex 32)
  ARD=$(openssl rand -hex 32)
  ARS=$(openssl rand -hex 32)
  JWT_KEY=$(openssl rand -hex 64)
  umask 077
  cat > "$SECRETS_FILE" <<EOF
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=1
SECRET_KEY_BASE=$SKB
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$ARP
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$ARD
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$ARS
DATABASE_URL=postgres://powernode@${DB_HOST}:5432/powernode_production
REDIS_URL=redis://${REDIS_HOST}:6379/0
# JWT signing for the platform's user-auth tokens. config/initializers/jwt.rb
# raises if JWT_SECRET_KEY is unset in production, and production defaults to
# RS256 (an RSA keypair, awkward as a multi-line PEM in this env file). A
# self-contained hub signs + verifies its own tokens, so HS256 with a random
# secret is sufficient (the agent/federation use mTLS + bootstrap tokens, not JWT).
JWT_ALGORITHM=HS256
JWT_SECRET_KEY=$JWT_KEY
EOF
  echo "[rails-start] Wrote $SECRETS_FILE"
fi

set -a
. "$SECRETS_FILE"
set +a

cd "$RAILS_DIR"

# --- Wait for postgres (sibling module powernode-postgres) ---
echo "[rails-start] Waiting for postgres on ${DB_HOST}:5432..."
for i in $(seq 1 30); do
  if /usr/bin/pg_isready -h "$DB_HOST" -p 5432 -U postgres >/dev/null 2>&1; then
    echo "[rails-start] postgres ready"
    break
  fi
  sleep 2
done

# --- Bootstrap postgres role + database ---
PSQL="/usr/bin/psql -h $DB_HOST -U postgres -tA"
if ! $PSQL -c "SELECT 1 FROM pg_roles WHERE rolname='powernode'" 2>/dev/null | grep -q 1; then
  echo "[rails-start] Creating powernode role"
  /usr/bin/psql -h "$DB_HOST" -U postgres -c "CREATE ROLE powernode WITH LOGIN SUPERUSER"
fi
if ! $PSQL -c "SELECT 1 FROM pg_database WHERE datname='powernode_production'" 2>/dev/null | grep -q 1; then
  echo "[rails-start] Creating powernode_production database"
  /usr/bin/psql -h "$DB_HOST" -U postgres -c "CREATE DATABASE powernode_production OWNER powernode"
fi

# --- Install gems from the module-vendored cache (offline, first-boot) ---
# Managed children have no rubygems.org egress, so the hub-backend module
# ships every .gem in server/vendor/cache (populated by `bundle cache` at
# build time — see .gitea/workflows/build-platform-modules.yaml) alongside a
# Gemfile.lock already resolved to the extension set this template mounts.
# `bundle install --local` therefore needs NO network: it installs from the
# cache and compiles native extensions here, on-instance, against runtime-ruby
# (build-essential + *-dev headers ship in that module) so they ABI-match.
#
# Still NOT --deployment: the parent's Gemfile.lock lists path gems for every
# extension (powernode_business, etc.), but an instance only mounts a subset.
# discover_extension_gems resolves the in-memory Gemfile to the mounted set;
# the build-time cache ran with the same set staged, so the shipped lock
# matches and --local resolves cleanly without --deployment's fatal-on-drift.
if [ ! -d vendor/bundle ] || [ -z "$(ls -A vendor/bundle 2>/dev/null)" ]; then
  echo "[rails-start] Installing gems from vendored cache (offline)"
  /usr/local/bin/bundle config set --local path 'vendor/bundle'
  /usr/local/bin/bundle config set --local without 'development:test'
  /usr/local/bin/bundle install --local --jobs 4
fi

# --- Migrate + seed (idempotent) ---
# The marker lives in the durable STATE_DIR: on the ephemeral overlay upper it
# vanished on every reboot, re-running the full first-boot seed forever.
MIGRATED_MARKER=$STATE_DIR/.db-initialized
# Carry over a marker written by a pre-STATE_DIR revision (persistent-root
# hosts; no-op when STATE_DIR already is /var/lib/powernode-rails).
if [ -f /var/lib/powernode-rails/.db-initialized ] && [ ! -f "$MIGRATED_MARKER" ]; then
  mv /var/lib/powernode-rails/.db-initialized "$MIGRATED_MARKER"
fi
if [ ! -f "$MIGRATED_MARKER" ]; then
  echo "[rails-start] db:migrate + first-admin bootstrap + db:seed (first boot)"
  /usr/local/bin/bundle exec rails db:migrate
  # Bootstrap the first admin BEFORE db:seed: the baseline seeds (AI provider
  # catalog + global platform agents + system-extension agents) resolve the
  # admin account/user, and a self-contained hub has no operator to click
  # through the setup wizard first. Idempotent (skips when a user exists);
  # writes credentials to $ADMIN_CREDS (mode 0600) — never to the journal.
  ADMIN_CREDS="$ADMIN_CREDS" /usr/local/bin/bundle exec rails runner /usr/local/bin/bootstrap-first-admin.rb
  /usr/local/bin/bundle exec rails db:seed
  touch "$MIGRATED_MARKER"
else
  echo "[rails-start] db already initialized; running pending migrations only"
  /usr/local/bin/bundle exec rails db:migrate
fi

echo "[rails-start] Starting puma"
exec /usr/local/bin/bundle exec puma -C config/puma.rb
