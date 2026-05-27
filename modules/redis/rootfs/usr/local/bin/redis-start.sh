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
chown redis:redis "$CONF"
chmod 0644 "$CONF"

echo "[redis-start] data=$DATA log=$LOG run=$RUN conf=$CONF"
exec runuser -u redis -- /usr/bin/redis-server "$CONF"
