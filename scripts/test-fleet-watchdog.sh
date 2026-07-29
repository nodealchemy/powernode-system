#!/usr/bin/env bash
# Tests for fleet-watchdog.sh. Drives the state machine through the
# transitions that matter using an injected probe, so no network, no target
# and no webhook endpoint are required.
#
# The transitions are the whole product here: a watchdog that alerts on every
# tick gets muted, one that never re-arms misses the second outage, and one
# that alerts below threshold cries wolf on a single dropped packet.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet-watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

cat > "$TMP/conf" <<EOF
TARGET_URL="https://example.invalid/api/v1/health"
TARGET_NAME="test-target"
FAIL_THRESHOLD=3
EOF

# Runs one tick. \$1 = "up" or "down". Echoes the script's stderr.
tick() {
  local mode="$1"
  local cmd='true'
  [ "$mode" = "down" ] && cmd='false'
  POWERNODE_WATCHDOG_CONFIG="$TMP/conf" \
  POWERNODE_WATCHDOG_STATE_DIR="$TMP/state" \
  PROBE_CMD="$cmd" \
  bash "$SCRIPT" 2>&1
}

reset_state() { rm -rf "$TMP/state"; }

# --- healthy target stays quiet ------------------------------------------
reset_state
out=$(tick up)
if [ -z "$out" ]; then ok "a healthy target produces no output"
else bad "a healthy target produces no output" "got: $out"; fi

# --- does not alert below threshold --------------------------------------
reset_state
out1=$(tick down); out2=$(tick down)
if ! printf '%s%s' "$out1" "$out2" | grep -q "ALERT"; then
  ok "no alert before FAIL_THRESHOLD is reached"
else bad "no alert before FAIL_THRESHOLD is reached" "alerted early"; fi

# --- alerts exactly at threshold -----------------------------------------
out3=$(tick down)
if printf '%s' "$out3" | grep -q "ALERT \[DOWN\]"; then
  ok "alerts on the Nth consecutive failure"
else bad "alerts on the Nth consecutive failure" "got: $out3"; fi

# --- does not re-alert while still down ----------------------------------
out4=$(tick down); out5=$(tick down)
if ! printf '%s%s' "$out4" "$out5" | grep -q "ALERT \[DOWN\]"; then
  ok "does not re-alert every tick while down"
else bad "does not re-alert every tick while down" "re-alerted"; fi

# --- recovery alert, and it reports a duration ---------------------------
out6=$(tick up)
if printf '%s' "$out6" | grep -q "ALERT \[RECOVERED\]"; then
  ok "alerts on recovery"
else bad "alerts on recovery" "got: $out6"; fi
if printf '%s' "$out6" | grep -qE 'after ~[0-9]+s'; then
  ok "recovery alert reports how long it was down"
else bad "recovery alert reports how long it was down" "got: $out6"; fi

# --- re-arms for the NEXT outage -----------------------------------------
# The failure mode this catches: latching 'alerted' and never clearing it, so
# the first outage is reported and every later one is silent.
out7=$(tick down); out8=$(tick down); out9=$(tick down)
if printf '%s%s%s' "$out7" "$out8" "$out9" | grep -q "ALERT \[DOWN\]"; then
  ok "re-arms and alerts on a subsequent outage"
else bad "re-arms and alerts on a subsequent outage" "stayed silent"; fi

# --- a flap resets the counter -------------------------------------------
reset_state
tick down >/dev/null; tick down >/dev/null
tick up   >/dev/null          # recovers before threshold
out=$(tick down; tick down)   # only two failures again
if ! printf '%s' "$out" | grep -q "ALERT \[DOWN\]"; then
  ok "a success resets the consecutive-failure counter"
else bad "a success resets the consecutive-failure counter" "counter carried over"; fi

# --- config errors are loud and distinct ---------------------------------
out=$(POWERNODE_WATCHDOG_CONFIG="$TMP/nope" bash "$SCRIPT" 2>&1); rc=$?
if [ "$rc" -eq 78 ] && printf '%s' "$out" | grep -q "FATAL"; then
  ok "missing config exits EX_CONFIG(78)"
else bad "missing config exits EX_CONFIG(78)" "rc=$rc out=$out"; fi

printf 'TARGET_NAME="x"\n' > "$TMP/noturl"
out=$(POWERNODE_WATCHDOG_CONFIG="$TMP/noturl" bash "$SCRIPT" 2>&1); rc=$?
if [ "$rc" -eq 78 ]; then
  ok "missing TARGET_URL exits EX_CONFIG(78) rather than defaulting"
else bad "missing TARGET_URL exits EX_CONFIG(78) rather than defaulting" "rc=$rc"; fi

# --- a failing probe must not make the unit fail -------------------------
# systemd would mark the service failed on every tick of a real outage,
# burying the signal in unit noise.
reset_state
POWERNODE_WATCHDOG_CONFIG="$TMP/conf" POWERNODE_WATCHDOG_STATE_DIR="$TMP/state" \
  PROBE_CMD='false' bash "$SCRIPT" >/dev/null 2>&1
if [ $? -eq 0 ]; then ok "a failed probe still exits 0"
else bad "a failed probe still exits 0" "non-zero exit"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
