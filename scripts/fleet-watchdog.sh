#!/usr/bin/env bash
# External liveness watchdog for a SELF-HOSTED Powernode control plane.
#
# WHY THIS CANNOT BE A FLEET SENSOR. The platform already ships exactly the
# right check: System::Fleet::Sensors::InstanceStatusSensor flags any instance
# whose last_heartbeat_at exceeds 3 minutes and emits `system.instance_silent`.
# It runs from SystemFleetReconcileJob — inside sidekiq.
#
# On 2026-07-28 ops-hub's agent detached its own platform stack, and the FIRST
# service stopped (23:51:00) was that sidekiq. The watchdog went down with the
# thing it watches. A self-hosted control plane cannot observe its own death,
# so the outage ran 51 minutes with nothing to notice it. Adding another
# in-platform sensor would reproduce the blind spot precisely.
#
# Hence: this runs OUTSIDE the failure domain — on the hypervisor host, which
# survives the guest by construction.
#
# Deliberately dependency-free (curl + coreutils) and deliberately dumb. A
# watchdog that can itself fail in interesting ways is not a watchdog. It does
# not touch the platform API, needs no credentials, and holds no state beyond
# a couple of integers.
#
# Install: see scripts/systemd/powernode-fleet-watchdog.{service,timer}
# Config:  /etc/powernode/fleet-watchdog.conf (see .example alongside it)
#
# NOT set -e: a failing probe is this script's normal control flow, not an
# error. Under -e the first unreachable probe would abort before it could
# alert — the exact moment the script exists for.
set -uo pipefail

CONFIG="${POWERNODE_WATCHDOG_CONFIG:-/etc/powernode/fleet-watchdog.conf}"
STATE_DIR="${POWERNODE_WATCHDOG_STATE_DIR:-/var/lib/powernode-watchdog}"

log() { printf '[fleet-watchdog] %s\n' "$*" >&2; }

if [ ! -r "$CONFIG" ]; then
  log "FATAL: config $CONFIG is missing or unreadable"
  exit 78 # EX_CONFIG
fi
# shellcheck disable=SC1090
. "$CONFIG"

# No hostnames, URLs or endpoints are baked into this file — every target is
# operator config. A missing target is a configuration error, never a default.
if [ -z "${TARGET_URL:-}" ]; then
  log "FATAL: TARGET_URL is not set in $CONFIG"
  exit 78
fi

TARGET_NAME="${TARGET_NAME:-$TARGET_URL}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"
WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_TIMEOUT="${WEBHOOK_TIMEOUT:-10}"
INSECURE="${INSECURE:-1}" # internal CA by default

# The probe is injectable ONLY so the test harness can drive state transitions
# without a network. Production never sets it.
default_probe() {
  local opts=(-sS -o /dev/null --max-time "$PROBE_TIMEOUT")
  [ "$INSECURE" = "1" ] && opts+=(-k)
  local code
  code=$(curl "${opts[@]}" -w '%{http_code}' "$TARGET_URL" 2>/dev/null)
  [ "$code" = "200" ]
}
probe() { if [ -n "${PROBE_CMD:-}" ]; then eval "$PROBE_CMD"; else default_probe; fi; }

mkdir -p "$STATE_DIR" 2>/dev/null || { log "FATAL: cannot create $STATE_DIR"; exit 73; }
slug=$(printf '%s' "$TARGET_NAME" | tr -c 'A-Za-z0-9_.-' '_')
STATE_FILE="$STATE_DIR/$slug.state"

fails=0; alerted=0; down_since=0
# shellcheck disable=SC1090
[ -r "$STATE_FILE" ] && . "$STATE_FILE"

write_state() {
  printf 'fails=%s\nalerted=%s\ndown_since=%s\n' "$1" "$2" "$3" > "$STATE_FILE.tmp" &&
    mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

# Alerting is best-effort and must NEVER abort the run: journald is the
# durable record, the webhook is the delivery attempt. If the webhook is the
# only channel and it fails silently, the outage is invisible again — so a
# failed POST is itself logged.
notify() {
  local status="$1" summary="$2"
  log "ALERT [$status] $TARGET_NAME: $summary"
  [ -z "$WEBHOOK_URL" ] && return 0

  local payload
  payload=$(printf '{"source":"powernode-fleet-watchdog","watcher":"%s","target":"%s","status":"%s","summary":"%s","url":"%s","ts":"%s"}' \
    "$(hostname -s 2>/dev/null || echo unknown)" "$TARGET_NAME" "$status" "$summary" "$TARGET_URL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

  if ! curl -sS -o /dev/null --max-time "$WEBHOOK_TIMEOUT" \
       -H 'Content-Type: application/json' -X POST -d "$payload" "$WEBHOOK_URL" 2>/dev/null; then
    log "WARN: webhook POST failed; alert recorded in journald only"
  fi
}

now=$(date +%s)

if probe; then
  if [ "$alerted" = "1" ]; then
    secs=$(( now - down_since ))
    [ "$down_since" -eq 0 ] && secs=0
    notify RECOVERED "reachable again after ~${secs}s unreachable"
  fi
  write_state 0 0 0
  exit 0
fi

fails=$(( fails + 1 ))
[ "$down_since" -eq 0 ] && down_since=$now

if [ "$alerted" = "0" ] && [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
  notify DOWN "failed $fails consecutive probes (threshold $FAIL_THRESHOLD)"
  alerted=1
else
  # Below threshold, or already alerted: log without re-notifying. Re-alerting
  # every tick trains people to mute the channel, which is how the next
  # outage gets missed.
  log "probe failed ($fails/$FAIL_THRESHOLD) for $TARGET_NAME"
fi

write_state "$fails" "$alerted" "$down_since"
exit 0
