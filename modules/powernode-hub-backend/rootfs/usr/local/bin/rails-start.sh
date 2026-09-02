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

# --- Internal CA store on the durable state dir ---
# System::InternalCaService defaults POWERNODE_CA_LOCAL_DIR to
# /var/lib/powernode/internal-ca. On a pivot-composed cell that path is the
# VOLATILE overlay upper, so the anchor CA -- and every cert issued from it --
# would be regenerated on each boot, breaking mTLS trust fleet-wide. Point it
# at STATE_DIR, which already resolves to /persist when that is a mountpoint
# and to /var/lib/powernode-rails otherwise. NOTE: on a non-pivot host that is
# a DIFFERENT path from the service default (/var/lib/powernode/internal-ca) --
# an earlier revision of this comment wrongly claimed such hosts were
# unaffected. Any store already at the old default is adopted by
# System::InternalCaService#adopt_legacy_store!, which imports it under the
# store lock and re-persists it here rather than minting a new anchor.
# Exported (not written to SECRETS_FILE): that file is authored on FIRST BOOT
# ONLY, so a node carrying a secrets file from an older image would never pick
# this up. An export runs every boot and reaches puma through the exec below.
#
# POWERNODE_CA_MODE is NOT exported here, but it IS pinned to "local" -- in the
# manifest (systemd env) and, for out-of-band rails processes, in the block that
# rewrites SECRETS_FILE below. An earlier revision of this comment argued the
# opposite and was wrong: resolve_default_mode probes Vault LIVE, so leaving the
# mode unset means the first restart after Vault becomes reachable silently
# switches this hub to a Vault-issued chain. That is a CA rotation -- every
# certificate the local anchor issued stops verifying -- and it belongs to a
# deliberate operator decision, not to a health probe.
: "${POWERNODE_CA_LOCAL_DIR:=$STATE_DIR/internal-ca}"
export POWERNODE_CA_LOCAL_DIR

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
  # Scope the 0600 umask to the secrets-file write ONLY, in a subshell, so it
  # does NOT leak into this process (and thence puma) — same leak class as the
  # CREDENTIAL_ENCRYPTION_KEY_DEFAULT append below. A leaked 077 umask made
  # Core::IngressConfigWriter write /etc/traefik/dynamic/00-host-login.yaml at
  # 0600 root → unreadable by the traefik user → all :443 → 404.
  ( umask 077
  cat > "$SECRETS_FILE" <<EOF
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=1
SECRET_KEY_BASE=$SKB
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$ARP
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$ARD
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$ARS
# DB connection is host-based (DATABASE_HOST), NOT a single DATABASE_URL. This
# app is Rails-8 multi-database: config/database.yml declares production
# primary/cache/queue/cable connections (solid_cache/solid_queue/solid_cable all
# on the same powernode_production DB, distinguished by connects_to role). A
# single DATABASE_URL collapses Rails to one unnamed "production" config, so the
# named :queue connection disappears and SolidQueue::Record's connects_to fails
# at eager_load — puma (config.eager_load=true) then cannot boot. The working
# platform runs with DATABASE_URL unset for exactly this reason; mirror it here.
# username=powernode is hard-set in each production config; password is unset →
# postgres trust auth (initdb default on this appliance).
DATABASE_HOST=${DB_HOST}
REDIS_URL=redis://${REDIS_HOST}:6379/0
# CACHE_STORE=memory_store + QUEUE_ADAPTER=async (table-free, since this hub ships
# no solid_cache/solid_queue tables) live in the module manifest env instead — that
# way they apply on EVERY boot via systemd Environment=, even when this secrets file
# was generated by an older image that predates them (this heredoc only runs on
# first-boot secret generation).
# JWT signing for the platform's user-auth tokens. config/initializers/jwt.rb
# raises if JWT_SECRET_KEY is unset in production, and production defaults to
# RS256 (an RSA keypair, awkward as a multi-line PEM in this env file). A
# self-contained hub signs + verifies its own tokens, so HS256 with a random
# secret is sufficient (the agent/federation use mTLS + bootstrap tokens, not JWT).
JWT_ALGORITHM=HS256
JWT_SECRET_KEY=$JWT_KEY
EOF
  )
  echo "[rails-start] Wrote $SECRETS_FILE"
fi

# --- Publish the resolved CA store settings for OUT-OF-BAND rails processes ---
# The export near the top reaches only puma's process tree. An operator
# `rails runner` or console resolves InternalCaService's DEFAULT_PERSIST_DIR
# instead and -- because LocalCaAdapter mints eagerly in #initialize, even for
# a read-shaped call like ca_fingerprint -- would create a SECOND, different CA.
# Publishing into SECRETS_FILE, which those invocations source, keeps every
# process on one store and one adapter mode.
#
# PLACEMENT IS LOAD-BEARING: this must run BEFORE the `set -a` sourcing below.
# A host whose /persist mount status just changed still has the PREVIOUS path in
# this file; sourced first, it would clobber the correct export from the top for
# exactly the boot where it matters -- minting an anchor on the now-volatile old
# path, then a second one next boot. Rewrite first, then source.
#
# REPLACE-or-append, every boot, never append-once.
#
# The rc check and the SECRET_KEY_BASE assertion are NOT belt-and-braces: a
# redirection that fails mid-stream (ENOSPC on /persist, which PGDATA shares)
# leaves a PARTIAL tmp file, and a same-filesystem rename needs no free space --
# so masking the error would atomically install a truncated secrets file.
# SECRET_KEY_BASE and the AR encryption keys are random, exist nowhere else, and
# already encrypt rows in the database: losing them is unrecoverable ciphertext.
# Any unforeseen partial-write mode must end as "original file kept".
if [ -f "$SECRETS_FILE" ]; then
  ( umask 077
    # Only POWERNODE_CA_MODE is rewritten. POWERNODE_CA_LOCAL_DIR is added ONLY
    # when absent: an existing value is a deployment's deliberate choice of
    # store, and rewriting it every boot would walk a live CA out from under
    # itself (see the default-not-override note further down).
    grep -v -E '^POWERNODE_CA_MODE=' "$SECRETS_FILE" > "$SECRETS_FILE.tmp"; rc=$?
    # grep: 0 = lines kept, 1 = none kept (benign), 2+ = read/write failure.
    [ "$rc" -le 1 ] || exit "$rc"
    grep -q '^POWERNODE_CA_LOCAL_DIR=' "$SECRETS_FILE.tmp" || \
      printf 'POWERNODE_CA_LOCAL_DIR=%s\n' "$POWERNODE_CA_LOCAL_DIR" >> "$SECRETS_FILE.tmp"
    printf 'POWERNODE_CA_MODE=%s\n' "local" >> "$SECRETS_FILE.tmp"
    grep -q '^SECRET_KEY_BASE=' "$SECRETS_FILE.tmp" || exit 1
    mv "$SECRETS_FILE.tmp" "$SECRETS_FILE" ) || \
    echo "[rails-start] WARNING: could not publish CA settings to $SECRETS_FILE (original kept)" >&2
fi

set -a
. "$SECRETS_FILE"
set +a

# CREDENTIAL_ENCRYPTION_KEY_DEFAULT — the AES-256 key Security::CredentialEncryptionService
# uses to encrypt operator-entered credentials (git/AI provider tokens, provider
# connections, ...). DISTINCT from the ActiveRecord encryption keys above and from
# SECRET_KEY_BASE. Production has NO Rails credentials file (config/credentials.yml.enc
# + master.key are gitignored and never shipped), and that service now fails closed
# without an explicit key — so the self-contained hub generates + persists its OWN,
# the same way it does SECRET_KEY_BASE (no DEV master key, no coupling). It is a
# base64-encoded 32 RAW bytes (openssl rand -base64 32 → Base64.decode64 == 32 bytes,
# what the service's validate_key_format expects) — NOT the -hex form the AR keys use.
# Idempotent ADD (not part of the first-boot heredoc) so a secrets file written by an
# OLDER image gains the key on the next boot without disturbing SECRET_KEY_BASE, the
# AR keys, or any already-encrypted data; regenerated only if genuinely absent.
if ! grep -q '^CREDENTIAL_ENCRYPTION_KEY_DEFAULT=' "$SECRETS_FILE"; then
  echo "[rails-start] Generating CREDENTIAL_ENCRYPTION_KEY_DEFAULT (credential-encryption key)"
  # Scope the 0600 umask to the append ONLY, in a subshell, so it does NOT
  # leak into this process (and thence puma). A leaked 077 umask made
  # Core::IngressConfigWriter write /etc/traefik/dynamic/00-host-login.yaml at
  # 0600 root → unreadable by the traefik user → all :443 → 404.
  ( umask 077; printf 'CREDENTIAL_ENCRYPTION_KEY_DEFAULT=%s\n' "$(openssl rand -base64 32)" >> "$SECRETS_FILE" )
  set -a
  . "$SECRETS_FILE"
  set +a
fi

# DEFAULT after the last sourcing -- never an override. An earlier revision
# assigned unconditionally here, which silently DEFEATED an operator-configured
# POWERNODE_CA_LOCAL_DIR carried in SECRETS_FILE: on ops-hub that pointed at a
# real CA store (/persist/powernode-internal-ca, holding the anchor AND the
# cosign module-signing material), and repointing puma at an empty directory
# would have made the next CA touch mint a fresh anchor and orphan it. This
# script's job is to SUPPLY a durable default where none is configured, not to
# overrule a deployment that has already chosen one.
: "${POWERNODE_CA_LOCAL_DIR:=$STATE_DIR/internal-ca}"
export POWERNODE_CA_LOCAL_DIR

cd "$RAILS_DIR"

# --- Render config/database.yml from the shipped template ---
# database.yml is gitignored, so the module ships only database.yml.example.
# Rails needs the FILE (not just DATABASE_URL) for its multi-database config —
# the production primary/cache/queue/cable connections that solid_cache /
# solid_queue / solid_cable resolve via connects_to. Without it, eager_load
# (config.eager_load=true in production) fails on SolidQueue::Record and puma
# cannot boot. The template renders entirely from ENV (DATABASE_HOST, trust
# auth), so a straight copy is the whole config. The overlay upper is ephemeral
# on pivot cells, so regenerate whenever it is missing.
if [ ! -f config/database.yml ]; then
  cp config/database.yml.example config/database.yml
  echo "[rails-start] Rendered config/database.yml from template"
fi

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

# INVARIANT (imp 019f77c5): this hub initializes + advances its DB with
# `db:migrate` ONLY — NEVER a bare `db:schema:load` / `db:setup` / `db:prepare`.
# Those load the CORE-ONLY schema.rb and `assume_migrated_upto_version`-stamp the
# private-extension migrations (timestamped below the core schema version) as
# applied WITHOUT running their DDL → a "stamped-without-DDL" drift db:migrate
# then skips forever (this is exactly what historically drifted ops-hub's
# system_node_instances.lifecycle_class — renamed to .lease_class by
# IMP-1e2e7b43b083, so grep for the new name). If a schema:load path is ever needed
# here, it MUST be followed by the un-assume-private-versions + db:migrate step
# from scripts/prepare-extension-test-db.sh. The check below is the backstop.

# --- Schema-drift backstop (advisory, NEVER fatal) --------------------------
# Catch a stamped-without-DDL drift and shout about it (log + System::FleetEvent);
# `|| true` + the script's own guards guarantee it can never fail the boot.
echo "[rails-start] schema-drift backstop check…"
/usr/local/bin/bundle exec rails runner /usr/local/bin/schema-drift-check.rb || true

# --- Governance policy reconcile (advisory, NEVER fatal) --------------------
# db:seed is FIRST BOOT ONLY, so a governance row added to a seed afterwards
# never reaches an established install (measured on ops-hub 2026-08-24: nine
# such rows had never landed). PolicyReconciler creates ONLY what is absent —
# it never updates a verb and never deletes, so an operator's tuned row is
# untouched. Runs in both branches above, after db:migrate. Always prints a
# summary line; `|| true` + the script's own guards keep a reconciler bug from
# failing the boot.
echo "[rails-start] governance policy reconcile…"
/usr/local/bin/bundle exec rails runner /usr/local/bin/governance-reconcile.rb || true

# --- Role-grant reconcile (advisory, NEVER fatal) ---------------------------
# Same shape, same reason, different table. db:seed is FIRST BOOT ONLY and every
# other caller of Role.sync_from_config! is first-install-only too, so a grant
# added to the permission catalog after an install's first boot never becomes a
# role_permissions row there — the operator is refused and NOTHING errors.
# Permissions::RoleGrantReconciler creates absence only; it never updates a role
# and never deletes a grant, so an out-of-catalog grant (including every grant
# belonging to an extension this boot did not compose) survives. Running
# Role.sync_from_config! here instead would DELETE those — it is full
# destructive reconciliation against the catalog loaded in this process.
echo "[rails-start] role-grant reconcile…"
/usr/local/bin/bundle exec rails runner /usr/local/bin/role-grants-reconcile.rb || true

# --- Ensure the host's own HTTPS login ingress for the bundled reverse proxy ---
# Root cause this closes (imp 019f6c3d): the reverse-proxy-traefik service runs
# `traefik` directly and never generates a dynamic config, and in extension mode
# Core::IngressConfigWriter.write! delegates to the ACME writer, which emits
# NOTHING without a valid System::AcmeCertificate for the hub's own hostname —
# so the login page was 404 after every boot. ensure_host_login_ingress! writes
# a self-signed, host-agnostic HTTPS config DIRECTLY (never touches the ACME
# seam), so the operator can always reach the UI/API. Idempotent.
#
# Persistence WITHOUT a re-provision: the serving cert lives on durable /persist
# (stable fingerprint — no per-boot churn), and the dynamic YAML is regenerated
# here every boot into the Traefik-watched dir (deterministic, references the
# /persist cert). Combined with the reverse-proxy-traefik module now shipping an
# /etc/traefik/dynamic placeholder (so the file provider never crashes on a
# missing dir), Traefik's file-watch picks this up live — no Traefik restart.
# Only runs when the traefik module is co-located (a hub-backend-only instance
# has no /etc/traefik to configure).
if [ -d /etc/traefik ]; then
  if mountpoint -q /persist 2>/dev/null; then
    TRAEFIK_CERT_DIR=/persist/powernode-traefik/certs
  else
    TRAEFIK_CERT_DIR=/var/lib/powernode-traefik/certs
  fi
  echo "[rails-start] Ensuring host login ingress (self-signed, host-agnostic) -> $TRAEFIK_CERT_DIR"
  mkdir -p /etc/traefik/dynamic "$TRAEFIK_CERT_DIR" || true
  cat > /tmp/ensure-host-login-ingress.rb <<RUBY
result = Core::IngressConfigWriter.ensure_host_login_ingress!(
  dynamic_dir: "/etc/traefik/dynamic",
  cert_dir:    "${TRAEFIK_CERT_DIR}"
)
abort("host-login ingress file missing after write: #{result[:output_path]}") unless File.exist?(result[:output_path])
RUBY
  # Verify+retry (ops-hub incident 2026-07-21): on a fresh boot, this
  # module-composed root is still being unioned together, and the
  # traefik module's own /etc/traefik layer can settle AFTER this script
  # runs. The write above can report success (no exception) yet the file
  # never lands on disk — observed live: 00-host-login.yaml absent despite
  # "ready" being logged, leaving Traefik to fall back to its own default
  # snakeoil cert (wrong CN, browser cert-authority-invalid warnings).
  # Re-run a few times, letting the Ruby script itself confirm the file
  # actually exists (File.exist?, aborts non-zero if not), before giving up.
  ingress_ready=0
  for attempt in 1 2 3 4 5; do
    if POWERNODE_INGRESS_HOST="${POWERNODE_INGRESS_HOST:-$(hostname -f 2>/dev/null || hostname)}" \
         /usr/local/bin/bundle exec rails runner /tmp/ensure-host-login-ingress.rb; then
      ingress_ready=1
      break
    fi
    echo "[rails-start] host login ingress attempt ${attempt} did not persist a file, retrying…"
    sleep 2
  done
  if [ "$ingress_ready" = "1" ]; then
    # The traefik service runs as User=traefik and must read the serving key
    # (written 0600). chown the durable cert tree to it; best-effort so a
    # missing user identity never aborts the boot.
    chown -R traefik:traefik "$(dirname "$TRAEFIK_CERT_DIR")" 2>/dev/null || true
    echo "[rails-start] host login ingress ready"
  else
    echo "[rails-start] host login ingress generation failed after retries (non-fatal — backend still starts)"
  fi
fi

echo "[rails-start] Starting puma"
exec /usr/local/bin/bundle exec puma -C config/puma.rb
