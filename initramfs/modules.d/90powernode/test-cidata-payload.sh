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

# --- routing is behavioural, not a prefix match ------------------------
# Source the functions only (CIDATA_SOURCE_ONLY) against a temp "mount" and
# check where each user-data shape lands. A provisioning document must reach the
# identity file whatever its layout; a federation payload must reach the
# federation path; the agent's strict parser (not this script) judges validity.
route_case() { # name content expect(identity|federation)
  _t=$(mktemp -d)
  printf '%s' "$2" > "$_t/user-data"
  (
    export CIDATA_SOURCE_ONLY=1 MNT="$_t" IDENTITY_DEST="$_t/identity.cfg" PAYLOAD_DEST="$_t/federation.json" ENROLL_CA_DEST="$_t/ca.pem"
    . "$SCRIPT" && stage_user_data
  ) >/dev/null 2>&1
  if [ "$3" = identity ] && [ -s "$_t/identity.cfg" ] && [ ! -e "$_t/federation.json" ]; then ok "$1 -> identity"
  elif [ "$3" = federation ] && [ -s "$_t/federation.json" ] && [ ! -e "$_t/identity.cfg" ]; then ok "$1 -> federation payload"
  else bad "$1 -> $3" "identity=$(ls "$_t"/identity.cfg 2>/dev/null) federation=$(ls "$_t"/federation.json 2>/dev/null)"; fi
  rm -rf "$_t"
}
route_case "compact v1 (version first)" '{"version":1,"key":"not-a-real-enrol-key"}' identity
route_case "reordered v1 (version last)" '{"key":"not-a-real-enrol-key","version":1}' identity
route_case "pretty-printed v1" "$(printf '{\n  "server": "https://p.example.test",\n  "version": 1\n}\n')" identity
route_case "case-variant VERSION key" '{"VERSION":1,"key":"x"}' identity
route_case "spaced key (\"version\" : 1)" '{"a":1, "version" : 1}' identity
route_case "federation payload with the word version only as a value" '{"parent_url":"https://p.example.test","note":"version"}' federation
route_case "legacy KEY= identity" "$(printf 'ID=abc\nKEY=not-a-real-enrol-key\n')" identity
route_case "federation payload (contract_version only)" '{"parent_url":"https://p.example.test","contract_version":"v1"}' federation

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
