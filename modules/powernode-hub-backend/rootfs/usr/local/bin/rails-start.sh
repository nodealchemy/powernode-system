#!/bin/bash
# rails-start.sh — first-boot Rails bootstrap + exec puma.
#
# On a fresh ops2-style spawn the module-mounted /opt/powernode/server
# tree is read-only (erofs lower); the overlay's writable upper holds
# any first-boot mutations. This wrapper handles everything Rails
# needs before puma can serve:
#   1. Generate Rails secrets (secret_key_base + AR encryption keys
#      + initial admin password) — persist to /etc/powernode/backend-
#      default.conf so subsequent boots reuse them.
#   2. Wait for postgres (sibling module on the same instance) to be
#      reachable on localhost:5432.
#   3. Create the powernode role + powernode_production database via
#      psql (as the postgres superuser; trust auth from initdb).
#   4. Vendor gems via bundle install --deployment — first-boot only,
#      slow (~5min) but cached for restarts.
#   5. db:migrate + db:seed (idempotent — Rails skips already-applied
#      migrations + seeds check find_or_create).
#   6. exec puma.
#
# The manifest sets user: root on this service so the wrapper can
# mkdir /etc/powernode + chown things. Puma itself runs as root for
# the duration (acceptable for the dogfood; production hardening
# would drop to a dedicated 'powernode' OS user via Puma config).
set -euo pipefail

SECRETS_FILE=/etc/powernode/backend-default.conf
ADMIN_CREDS=/etc/powernode/admin-credentials.json
RAILS_DIR=/opt/powernode/server

mkdir -p /etc/powernode

# --- Generate secrets if missing (first-boot only) ---
if [ ! -f "$SECRETS_FILE" ]; then
  echo "[rails-start] Generating Rails secrets..."
  SKB=$(openssl rand -hex 64)
  ARP=$(openssl rand -hex 32)
  ARD=$(openssl rand -hex 32)
  ARS=$(openssl rand -hex 32)
  ADMIN_PW=$(openssl rand -hex 16)
  umask 077
  cat > "$SECRETS_FILE" <<EOF
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=1
SECRET_KEY_BASE=$SKB
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$ARP
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$ARD
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$ARS
DATABASE_URL=postgres://powernode@localhost:5432/powernode_production
REDIS_URL=redis://localhost:6379/0
POWERNODE_INITIAL_ADMIN_PASSWORD=$ADMIN_PW
EOF
  cat > "$ADMIN_CREDS" <<EOF
{
  "email": "admin@powernode.org",
  "password": "$ADMIN_PW",
  "generated_at": "$(date -Iseconds)",
  "note": "Stored at $ADMIN_CREDS mode 0600 for operator retrieval."
}
EOF
  echo "[rails-start] Wrote $SECRETS_FILE + $ADMIN_CREDS"
fi

set -a
. "$SECRETS_FILE"
set +a

cd "$RAILS_DIR"

# --- Wait for postgres (sibling module powernode-postgres) ---
echo "[rails-start] Waiting for postgres on localhost:5432..."
for i in $(seq 1 30); do
  if /usr/bin/pg_isready -h localhost -p 5432 -U postgres >/dev/null 2>&1; then
    echo "[rails-start] postgres ready"
    break
  fi
  sleep 2
done

# --- Bootstrap postgres role + database ---
PSQL="/usr/bin/psql -h localhost -U postgres -tA"
if ! $PSQL -c "SELECT 1 FROM pg_roles WHERE rolname='powernode'" 2>/dev/null | grep -q 1; then
  echo "[rails-start] Creating powernode role"
  /usr/bin/psql -h localhost -U postgres -c "CREATE ROLE powernode WITH LOGIN SUPERUSER"
fi
if ! $PSQL -c "SELECT 1 FROM pg_database WHERE datname='powernode_production'" 2>/dev/null | grep -q 1; then
  echo "[rails-start] Creating powernode_production database"
  /usr/bin/psql -h localhost -U postgres -c "CREATE DATABASE powernode_production OWNER powernode"
fi

# --- Vendor gems (first-boot only; ~5 min cold) ---
# NOT using --deployment because parent's Gemfile.lock includes
# all extension submodules' path gems (powernode_business, etc.)
# whereas ops2 only mounts extension-system. Gemfile dynamically
# resolves via discover_extension_gems so the in-memory Gemfile
# diverges from the on-disk Gemfile.lock; --deployment treats
# that divergence as fatal. Without --deployment, bundle adapts
# the lock at install time to match the actual mounted extensions.
if [ ! -d vendor/bundle ] || [ -z "$(ls -A vendor/bundle 2>/dev/null)" ]; then
  echo "[rails-start] Vendoring gems (first boot)"
  /usr/bin/bundle config set --local path 'vendor/bundle'
  /usr/bin/bundle config set --local without 'development:test'
  /usr/bin/bundle install --jobs 4 --retry 2
fi

# --- Migrate + seed (idempotent) ---
MIGRATED_MARKER=/var/lib/powernode-rails/.db-initialized
mkdir -p /var/lib/powernode-rails
if [ ! -f "$MIGRATED_MARKER" ]; then
  echo "[rails-start] db:migrate + db:seed (first boot)"
  /usr/bin/bundle exec rails db:migrate
  /usr/bin/bundle exec rails db:seed
  touch "$MIGRATED_MARKER"
else
  echo "[rails-start] db already initialized; running pending migrations only"
  /usr/bin/bundle exec rails db:migrate
fi

echo "[rails-start] Starting puma"
exec /usr/bin/bundle exec puma -C config/puma.rb
