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

echo "[redis-start] data=$DATA log=$LOG run=$RUN"
exec runuser -u redis -- /usr/bin/redis-server /etc/redis/redis.conf
