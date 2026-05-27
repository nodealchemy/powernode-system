#!/bin/bash
# postgres-start.sh — first-boot init + exec postgres.
#
# The module ships /usr/lib/postgresql/16/bin/postgres + apt-installed
# server, but DELIBERATELY omits /var (runtime state belongs in the
# overlay's writable upper layer, not the read-only erofs lower). On
# first boot, /var/lib/postgresql/16/main is empty — postgres would
# fail with "data directory not initialized" without this wrapper.
#
# Run as root so the wrapper can mkdir + chown before dropping to the
# postgres user via runuser. The manifest sets user: root on the
# systemd service for this reason; postgres itself executes as the
# postgres user via runuser at the end.
set -euo pipefail

DATA=/var/lib/postgresql/16/main
RUN=/var/run/postgresql
LOG=/var/log/postgresql

mkdir -p "$DATA" "$RUN" "$LOG" /var/lib/postgresql
chown -R postgres:postgres /var/lib/postgresql "$RUN" "$LOG"
chmod 700 "$DATA"

if [ ! -f "$DATA/PG_VERSION" ]; then
  # The apt postgresql-16 install leaves a PARTIAL default cluster baked
  # into the module's erofs layer (base/, global/, pg_*/ dirs but no
  # PG_VERSION — apt's postinst initdb is skipped in the build chroot).
  # initdb refuses a non-empty target dir, so clear any baked/stale
  # content first. Safe because the absence of PG_VERSION means there's
  # no real cluster here — only build-artifact debris or a half-finished
  # prior init. Real clusters (with PG_VERSION) skip this whole block.
  if [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
    echo "[postgres-start] $DATA non-empty but no PG_VERSION — clearing build-artifact debris before initdb"
    find "$DATA" -mindepth 1 -delete
  fi
  echo "[postgres-start] Initializing cluster at $DATA (trust auth, UTF8)"
  runuser -u postgres -- /usr/lib/postgresql/16/bin/initdb \
    -D "$DATA" \
    --auth-local=trust \
    --auth-host=md5 \
    -U postgres \
    -E UTF8 \
    --locale=C.UTF-8
fi

# Deterministic config, robust to BOTH cluster layouts:
#   - initdb-style (our initdb above) keeps postgresql.conf + pg_hba.conf IN
#     the data dir.
#   - Debian pg_createcluster-style keeps them in /etc/postgresql/16/main
#     (read-only erofs here) and leaves the data dir without them.
# Earlier revisions grep'd/edited these files in place; under `set -e` a grep
# against a non-existent data-dir file aborted the whole script before exec,
# and pointing -c config_file at Debian's /etc copy loaded `ssl = on` against
# the root-owned snakeoil key the dropped postgres user can't read. Instead we
# author self-contained config files in the (writable, postgres-owned) data dir
# every boot. Postgres supplies compiled defaults for everything we omit; we
# only pin what this localhost-loopback hub DB needs. ssl stays off (TLS adds
# nothing on 127.0.0.1 trust auth, and avoids the unreadable snakeoil key).
CONF="$DATA/postgresql.conf"
HBA="$DATA/pg_hba.conf"

# Preserve an initdb-generated conf if present (keeps locale/encoding GUCs),
# else start empty for a Debian-style cluster. Then re-apply our managed block
# last so it wins regardless of prior content (idempotent across restarts).
[ -f "$CONF" ] || : > "$CONF"
sed -i '/# >>> powernode-managed/,/# <<< powernode-managed/d' "$CONF" 2>/dev/null || true
cat >> "$CONF" <<EOF
# >>> powernode-managed (do not edit between markers)
listen_addresses = 'localhost'
unix_socket_directories = '$RUN'
ssl = off
# <<< powernode-managed
EOF

# Self-contained pg_hba: trust local socket + loopback TCP (hub services connect
# via DATABASE_URL over 127.0.0.1). Authored fresh so a missing/Debian-located
# file can't abort the script.
cat > "$HBA" <<EOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
EOF

chown postgres:postgres "$CONF" "$HBA"
chmod 0600 "$CONF" "$HBA"

echo "[postgres-start] Starting postgres -D $DATA (config_file=$CONF)"
exec runuser -u postgres -- /usr/lib/postgresql/16/bin/postgres \
  -D "$DATA" \
  -c config_file="$CONF" \
  -c hba_file="$HBA"
