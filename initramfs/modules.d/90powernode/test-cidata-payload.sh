#!/usr/bin/env bash
# Tests for powernode-cidata-payload.sh's device-enumeration guard.
#
# The guard is the whole bug: it decides "no NoCloud drive, nothing to stage"
# and exits 0 SILENTLY, which is both the correct behaviour for a node with no
# CD-ROM and — before the wait was added — the failure mode when /dev/sr0 had
# simply not enumerated yet. ops-cell's first boot took that exit and its agent
# never found an identity.
#
# These run on a host with no optical device, so the "absent" path is the one
# under test. The properties that matter:
#   1. it still exits 0 (must never fail a boot)
#   2. it still exits FAST when the device is genuinely absent (the original
#      "latency-free" property must survive the fix)
#   3. it DOES wait when told to (the fix is actually wired up)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/powernode-cidata-payload.sh"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# Point the guard at a path that cannot exist, so the "absent" branch is
# under test regardless of whether the HOST has an optical device. Without
# this the suite silently skipped on any developer machine with /dev/sr0 —
# i.e. exactly where it would have been run.
export CIDATA_DEVICES="/nonexistent/cidata-probe-$$"

# --- syntax -------------------------------------------------------------
if sh -n "$SCRIPT" 2>/dev/null; then ok "script is valid POSIX sh"
else bad "script is valid POSIX sh" "$(sh -n "$SCRIPT" 2>&1 | head -2)"; fi

# --- never fails a boot -------------------------------------------------
out=$(CIDATA_DEVICES="$CIDATA_DEVICES" CIDATA_SETTLE_TIMEOUT=1 CIDATA_WAIT_SECONDS=1 sh "$SCRIPT" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok "exits 0 when no NoCloud drive is present"
else bad "exits 0 when no NoCloud drive is present" "rc=$rc out=$out"; fi

if printf '%s' "$out" | grep -q "nothing to stage"; then
  ok "reports why it did nothing"
else bad "reports why it did nothing" "got: $out"; fi

# --- the fix is wired up ------------------------------------------------
# With a 3s budget the run must take AT LEAST ~3s, proving the wait loop is
# actually reached rather than the guard short-circuiting as before.
start=$(date +%s)
CIDATA_DEVICES="$CIDATA_DEVICES" CIDATA_SETTLE_TIMEOUT=1 CIDATA_WAIT_SECONDS=3 sh "$SCRIPT" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -ge 3 ]; then ok "waits for enumeration before declaring absence (${elapsed}s)"
else bad "waits for enumeration before declaring absence" "returned in ${elapsed}s; wait loop not reached"; fi

# --- the fast path survives --------------------------------------------
# A node with genuinely no optical device must not pay a long penalty. With
# the wait disabled the run should be near-instant.
start=$(date +%s)
CIDATA_DEVICES="$CIDATA_DEVICES" CIDATA_SETTLE_TIMEOUT=1 CIDATA_WAIT_SECONDS=0 sh "$SCRIPT" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le 2 ]; then ok "stays fast when the wait budget is zero (${elapsed}s)"
else bad "stays fast when the wait budget is zero" "took ${elapsed}s"; fi

# --- it announces the wait ---------------------------------------------
out=$(CIDATA_DEVICES="$CIDATA_DEVICES" CIDATA_SETTLE_TIMEOUT=1 CIDATA_WAIT_SECONDS=2 sh "$SCRIPT" 2>&1)
if printf '%s' "$out" | grep -q "waited .*s for a NoCloud drive"; then
  ok "logs that it waited, so a slow enumeration is diagnosable"
else bad "logs that it waited" "got: $out"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
