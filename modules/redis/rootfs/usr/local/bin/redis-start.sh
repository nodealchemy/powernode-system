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

# Persistence goes on /persist, NOT under $DATA. $DATA lives on the composed
# root's tmpfs upper (512 MB total), and a snapshot rewrite forks and writes a
# SECOND copy alongside the existing one — so a dataset of even ~255 MB can
# never save there. Redis then latches MISCONF and refuses EVERY write until a
# save succeeds. Observed on ops-hub-dev-cell 2026-07-31:
# rdb_last_bgsave_status:err, overlay at 51%, and ~100 specs failing across
# every Redis-backed service (working memory, pacing, caches) with no obvious
# cause. /persist is the node's durable store and has room.
PERSIST_DATA=/persist/redis

mkdir -p "$DATA" "$LOG" "$RUN" "$PERSIST_DATA"
chown -R redis:redis "$DATA" "$LOG" "$RUN"
chown redis:redis "$PERSIST_DATA"
chmod 750 "$DATA" "$PERSIST_DATA"

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
# Move persistence off the overlay (see PERSIST_DATA above). Done by sed on the
# staged copy so it holds regardless of the include below.
sed -i "s#^[[:space:]]*dir[[:space:]].*#dir ${PERSIST_DATA}#" "$CONF"

# Load the module's own overrides.
#
# The apt redis.conf carries NO `include` directive — Debian does not read
# conf.d despite the long-standing comment claiming it did — so
# /etc/redis/conf.d/*.conf had never taken effect on any node. The module
# declared AOF persistence for Sidekiq durability and RDB snapshots disabled,
# and neither was ever true: AOF was off, and the RDB snapshotting the module
# meant to disable is what filled a 512 MB tmpfs overlay and wedged a node into
# MISCONF, refusing every write.
#
# Appended LAST so these win: redis takes the last occurrence of a directive,
# and everything above came from the apt file. The drop-in deliberately does
# NOT set maxmemory/eviction or the bind — see the header in powernode.conf for
# why shipping those would have been wrong.
#
# Glob, not a fixed filename, so an operator drop-in also applies. Guarded so a
# node without the directory still starts.
if compgen -G "/etc/redis/conf.d/*.conf" >/dev/null 2>&1; then
  printf '\n# Loaded by redis-start.sh — see modules/redis/rootfs/etc/redis/conf.d/\ninclude /etc/redis/conf.d/*.conf\n' >> "$CONF"
fi

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
