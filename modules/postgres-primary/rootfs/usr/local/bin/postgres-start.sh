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

# Allow local TCP connections from co-located services (rails, sidekiq).
# Without this, hub-backend's DATABASE_URL=postgres://powernode@localhost
# fails because the default pg_hba.conf trusts only Unix-socket.
HBA="$DATA/pg_hba.conf"
if ! grep -qE '^host\s+all\s+all\s+127\.0\.0\.1/32\s+trust' "$HBA"; then
  echo "host    all             all             127.0.0.1/32            trust" >> "$HBA"
  echo "host    all             all             ::1/128                 trust" >> "$HBA"
fi

# listen_addresses defaults to localhost only — keep that, but make
# sure it's set (some apt configs comment it out).
CONF="/etc/postgresql/16/main/postgresql.conf"
if [ -w "$CONF" ] && ! grep -qE '^\s*listen_addresses' "$CONF"; then
  echo "listen_addresses = 'localhost'" >> "$CONF"
fi
if [ -w "$CONF" ] && ! grep -qE '^\s*unix_socket_directories' "$CONF"; then
  echo "unix_socket_directories = '$RUN'" >> "$CONF"
fi

# Debian's postgresql.conf ships `ssl = on` pointing at the snakeoil cert
# (/etc/ssl/private/ssl-cert-snakeoil.key, root:ssl-cert 0640). The backend
# drops to the `postgres` user, which isn't in the ssl-cert group inside the
# erofs, so it dies with "could not access private key file ... Permission
# denied". This is a localhost-only DB (listen_addresses=localhost, trust on
# 127.0.0.1) reached by the hub over the loopback — TLS adds nothing here, so
# force it off rather than ship a readable key into the image.
echo "[postgres-start] Starting postgres -D $DATA"
exec runuser -u postgres -- /usr/lib/postgresql/16/bin/postgres \
  -D "$DATA" \
  -c config_file="$CONF" \
  -c hba_file="$HBA" \
  -c ssl=off
