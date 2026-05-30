#!/bin/bash
# redis-start.sh — ensure data dir + exec redis-server.
#
# /var is omitted from the module's file_spec (runtime state belongs
# in the overlay's writable upper, not the erofs lower) so on first
# boot /var/lib/redis doesn't exist and redis-server can't open its
# RDB/AOF persistence files.
#
# Manifest sets user: root for this service; redis-server drops to
# the redis user itself once started via its own privilege handling.
set -euo pipefail

DATA=/var/lib/redis
LOG=/var/log/redis
RUN=/var/run/redis

mkdir -p "$DATA" "$LOG" "$RUN"
chown -R redis:redis "$DATA" "$LOG" "$RUN"
chmod 750 "$DATA"

# redis.conf ships root:root 0640 in the erofs (mkfs.erofs --all-root bakes
# every file root-owned), so the dropped redis user can't read it from the
# read-only lower ("can't open config file '/etc/redis/redis.conf':
# Permission denied"). Stage a redis-readable copy on the writable data dir
# (we hold CAP_DAC_OVERRIDE + CAP_FOWNER to read the source + fix the copy).
CONF="$DATA/redis.conf"
cp /etc/redis/redis.conf "$CONF"
# Log to stderr (journal) rather than a file so startup failures are visible;
# the file logfile in the apt conf otherwise swallows the reason redis exits.
sed -i 's#^[[:space:]]*logfile[[:space:]].*#logfile ""#' "$CONF"
# Force foreground. The apt redis.conf ships `daemonize yes`; under a
# Type=simple systemd unit that makes redis-server fork while the exec'd
# foreground process exits 0, so systemd marks the service "deactivated"
# and restart-loops it. Pin daemonize off so systemd tracks the real server.
sed -i 's#^[[:space:]]*daemonize[[:space:]].*#daemonize no#' "$CONF"
chown redis:redis "$CONF"
chmod 0644 "$CONF"

# The erofs ships /usr/bin/redis-server as a symlink to the redis-check-rdb
# multi-call binary. redis selects server-vs-checker mode from its invoked
# name (/proc/self/exe), so executing through the symlink runs the RDB checker
# — which exits immediately with no log. Stage a real copy named "redis-server"
# on the writable data dir so the mode dispatch resolves to the server.
SRV="$DATA/redis-server"
install -m 0755 "$(readlink -f /usr/bin/redis-server)" "$SRV"

echo "[redis-start] data=$DATA log=$LOG run=$RUN conf=$CONF bin=$SRV"
exec runuser -u redis -- "$SRV" "$CONF"
