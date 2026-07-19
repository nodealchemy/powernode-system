#!/bin/bash
# dev-cell-dev-db.sh — ensure the operator's local development database exists.
#
# Creates the `powernode` Postgres role (superuser, trust auth on
# 127.0.0.1 — matching server/config/database.yml.example's DATABASE_USER
# default) and an empty `powernode_development` database, so the operator can
# `cd workspace/server && bin/rails db:migrate` from the cloned source without
# first hitting "role powernode does not exist". Mirrors the pg-role step
# dev-cell-provision-pnagent.sh already uses for the autonomous path.
#
# Creds-free: local trust-auth Postgres only, no secrets. Idempotent — safe on
# every boot; each object is created only if absent, never dropped/recreated
# (a real dev DB with the operator's data survives). Postgres data lives on
# /persist (postgres-primary keeps PGDATA there), so the DB persists too.
set -euo pipefail

log() { echo "dev-cell-dev-db: $*"; }

ROLE="${DEV_CELL_DB_ROLE:-powernode}"
DEVDB="${DEV_CELL_DEV_DB:-powernode_development}"

# Postgres (postgres-primary module) comes up independently; wait for it
# rather than racing. Bounded so a genuinely-absent Postgres fails the unit
# (visible) instead of hanging forever.
for _ in $(seq 1 60); do
  if pg_isready -h 127.0.0.1 -q; then break; fi
  sleep 2
done
pg_isready -h 127.0.0.1 -q || { log "Postgres not ready on 127.0.0.1 after 120s — is postgres-primary co-assigned + up?"; exit 1; }

if ! psql -h 127.0.0.1 -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ROLE}'" 2>/dev/null | grep -q '^1$'; then
  createuser -h 127.0.0.1 -U postgres -s "$ROLE"
  log "created Postgres role '${ROLE}' (superuser, trust auth)"
else
  log "Postgres role '${ROLE}' already exists"
fi

if ! psql -h 127.0.0.1 -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DEVDB}'" 2>/dev/null | grep -q '^1$'; then
  createdb -h 127.0.0.1 -U postgres -O "$ROLE" "$DEVDB"
  log "created empty database '${DEVDB}' (owner ${ROLE}) — operator runs bin/rails db:migrate from source"
else
  log "database '${DEVDB}' already exists"
fi
