#!/bin/bash
# dev-cell-provision-pnagent.sh — the UNPRIVILEGED half of dev-cell
# workspace provisioning: everything that does NOT need the Gitea deploy
# key (which stays root-only — see dev-cell-provision.sh). Invoked via
# `runuser -u pnagent` from dev-cell-provision.sh AFTER it has cloned the
# repo and chowned the workspace to pnagent — never run standalone, and
# never run as root.
#
# Runs the SAME build steps scripts/validate.sh will later need (bundle,
# npm, the test DB), as the SAME user (pnagent) that later actually runs
# validate.sh — so nothing here needs re-doing or re-permissioning at
# validate time.
#
# ADAPTED from scripts/prepare-worktree.sh and
# scripts/prepare-extension-test-db.sh for a standalone-instance first
# boot rather than a worktree-of-a-main-checkout — see
# dev-cell-provision.sh's own header comment for the full rationale.
#
# Idempotent: shares dev-cell-provision.sh's $STATE_DIR/state marker
# convention (that directory is chowned to pnagent by the caller before
# this script ever runs), so a re-run resumes instead of redoing finished
# work.
set -euo pipefail

WORKDIR="${DEV_CELL_WORKDIR:?DEV_CELL_WORKDIR not set — this script must be invoked by dev-cell-provision.sh, not run standalone}"
STATE_DIR="${DEV_CELL_STATE_DIR:?DEV_CELL_STATE_DIR not set — this script must be invoked by dev-cell-provision.sh, not run standalone}"
STEP_DIR="$STATE_DIR/state"

# BUG-D: keep npm's download cache on the durable /persist volume (a
# pnagent-owned dir pre-created by dev-cell-provision.sh), not the 512M tmpfs
# root overlay it would otherwise hit via pnagent's $HOME (~/.npm). vendor/
# bundle and node_modules already land under $WORKDIR (also on /persist), so
# this closes the last big writer that would otherwise fill the overlay.
export npm_config_cache="${DEV_CELL_NPM_CACHE:-$(dirname "$WORKDIR")/npm-cache}"

# BUG-H: `npm ci` (frontend deps below) otherwise downloads the Cypress binary
# — a ~237M .zip staged in TMPDIR plus a ~245M extracted tree in
# ~/.cache/Cypress. pnagent's $HOME and the default /tmp both sit on the 512M
# tmpfs root overlay (only $WORKDIR + the npm cache are redirected to /persist),
# so that download overflows the overlay to 100% → the co-located Postgres then
# dies "No space left on device" on its socket lock, failing provision. Nothing
# in scripts/validate.sh runs Cypress (it runs rspec + tsc + pattern-validation
# + gitleaks only), so skip the binary download entirely — npm ci still installs
# the cypress npm package for a coherent node_modules, just not its 240M binary.
export CYPRESS_INSTALL_BINARY=0

log() { echo "dev-cell-provision-pnagent: $*"; }
done_step() { [ -e "$STEP_DIR/$1" ]; }
mark_step() { mkdir -p "$STEP_DIR"; : > "$STEP_DIR/$1"; }

cd "$WORKDIR"

# --- 1. gitignored runtime configs from the repo's own tracked templates -
# No sibling "main checkout" to symlink from on a standalone instance —
# generate fresh from the tracked *.example files instead.
if ! done_step runtime-config; then
  [ -f server/config/database.yml ] || cp server/config/database.yml.example server/config/database.yml
  [ -f server/.env ] || cp server/.env.example server/.env
  [ -f worker/.env ] || cp worker/.env.example worker/.env
  mark_step runtime-config
  log "runtime configs generated from tracked *.example templates (server/config/database.yml, server/.env, worker/.env)"
fi

# --- 2. bundle Ruby deps ---------------------------------------------------
if ! done_step bundle; then
  # pnagent is unprivileged and CANNOT write the system gem dir
  # (/var/lib/gems/... is root-owned), so a bare `bundle install` fails with
  # Bundler::PermissionError. Pin bundler to a workspace-local, pnagent-owned
  # vendor/bundle via a --local .bundle/config — which scripts/validate.sh's
  # later `bundle exec` transparently reuses (same per-project .bundle/config),
  # so no gems ever need to land in the root-owned system path.
  (cd server && { bundle config set --local path vendor/bundle; bundle check >/dev/null 2>&1 || bundle install; })
  (cd worker && { bundle config set --local path vendor/bundle; bundle check >/dev/null 2>&1 || bundle install; })
  if [ -f server/Gemfile.private ]; then
    (cd server && { BUNDLE_GEMFILE=Gemfile.private bundle check >/dev/null 2>&1 || BUNDLE_GEMFILE=Gemfile.private bundle install; })
  fi
  mark_step bundle
  log "bundle install complete"
fi

# --- 3. frontend deps -------------------------------------------------------
if ! done_step frontend; then
  (cd frontend && { [ -d node_modules ] || npm ci; })
  mark_step frontend
  log "frontend npm dependencies installed"
fi

# --- 4. wait for local Postgres to accept connections -----------------------
# postgres-primary's own unit can still be starting up (initdb + first
# start) when this phase reaches the DB step — poll pg_isready rather
# than assume co-located services already raced to readiness.
if ! done_step pg-ready; then
  log "waiting for local Postgres to accept connections..."
  ready=0
  for _ in $(seq 1 60); do
    if pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  [ "$ready" = "1" ] || { log "Postgres never became ready at 127.0.0.1 after 120s"; exit 1; }
  mark_step pg-ready
  log "Postgres is ready"
fi

# --- 5. ensure the `powernode` Postgres role exists -------------------------
# postgres-primary's postgres-start.sh only runs `initdb -U postgres` — no
# `powernode` role is ever created. Without this,
# db:create/db:test:prepare (both driven by server/config/database.yml
# .example's DATABASE_USER=powernode default) die "role powernode does not
# exist". `psql -h 127.0.0.1` is TCP/trust-auth — the DB role check below
# is keyed on `-U postgres`, not the calling OS user, so running this as
# pnagent instead of root makes no difference here. Idempotent: safe to
# re-assert on every boot.
if ! done_step pg-role; then
  if ! psql -h 127.0.0.1 -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='powernode'" 2>/dev/null | grep -q '^1$'; then
    createuser -h 127.0.0.1 -U postgres -s powernode
    log "created Postgres role 'powernode' (superuser, trust auth)"
  else
    log "Postgres role 'powernode' already exists"
  fi
  mark_step pg-role
fi

# --- 6. test database -------------------------------------------------------
# Reuses the CLONED repo's OWN script — it already handles core-vs-private
# mode and the golden-template fast path; do not reimplement it here.
if ! done_step test-db; then
  bash scripts/prepare-extension-test-db.sh
  mark_step test-db
  log "test database prepared"
fi

log "pnagent-side provisioning complete"
