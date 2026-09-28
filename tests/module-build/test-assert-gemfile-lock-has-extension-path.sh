#!/usr/bin/env bash
# test-assert-gemfile-lock-has-extension-path.sh — self-contained test suite
# for scripts/module-build/assert-gemfile-lock-has-extension-path.sh
# (IMP-094d900f9093).
#
# WHY THIS EXISTS: stage15.sh's powernode-hub-backend arm re-locks
# server/Gemfile.lock on the builder to vendor an offline gem cache. That
# re-lock silently dropped the system extension's PATH gem when nothing
# staged extensions/system on the builder first — a lock that "resolved
# without error" but was WRONG (core-only) for how the module actually
# deploys. The re-lock itself needs network + a real bundler, so it isn't
# testable here; this script IS the build-time assertion the fix adds
# right after it, and it's pure text processing — directly testable
# against small fixture Gemfile.lock files with no bundler/network at all.
#
# Same harness convention as test-stage-extension-system-files.sh: no bats
# dependency, plain bash + a small assert helper, subprocess invocation so
# a non-zero exit is observable without tripping this test's own strict
# mode.
#
# Usage: bash tests/module-build/test-assert-gemfile-lock-has-extension-path.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../../scripts/module-build/assert-gemfile-lock-has-extension-path.sh"

PASS_COUNT=0
FAIL_COUNT=0

ok()   { PASS_COUNT=$((PASS_COUNT + 1)); echo "  ok   - $1"; }
bad()  { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$desc"
  else
    bad "$desc (expected [$expected], got [$actual])"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ok "$desc" ;;
    *) bad "$desc (expected output to contain [$needle])" ;;
  esac
}

# Runs the script as a subprocess, capturing combined stdout+stderr into
# $RUN_OUT and the exit code into $RUN_RC.
run_cli() {
  RUN_OUT=$(bash "$SCRIPT" "$@" 2>&1)
  RUN_RC=$?
}

echo "=== GREEN: a lock with the expected PATH section ==="
{
  LOCK=$(mktemp)
  cat > "$LOCK" <<'EOF'
PATH
  remote: ../extensions/marketing/server
  specs:
    powernode_marketing (0.1.0)

PATH
  remote: ../extensions/system/server
  specs:
    powernode_system (0.1.0)
      rails (~> 8.1)

GEM
  remote: https://rubygems.org/
  specs:
    rails (8.1.0)

DEPENDENCIES
  powernode_system!

BUNDLED WITH
   2.7.1
EOF

  run_cli --lock "$LOCK" --gem powernode_system --remote ../extensions/system/server

  assert_eq "correct PATH section: exit 0" "0" "$RUN_RC"
  assert_contains "correct PATH section: reports OK" "$RUN_OUT" "OK"

  rm -f "$LOCK"
}

echo "=== RED: a core-only lock (the actual IMP-094d900f9093 symptom) — no PATH section at all ==="
{
  LOCK=$(mktemp)
  cat > "$LOCK" <<'EOF'
GEM
  remote: https://rubygems.org/
  specs:
    rails (8.1.0)

DEPENDENCIES
  rails

BUNDLED WITH
   2.7.1
EOF

  run_cli --lock "$LOCK" --gem powernode_system --remote ../extensions/system/server

  assert_eq "core-only lock: exit 1" "1" "$RUN_RC"
  assert_contains "core-only lock: FATAL names the gem" "$RUN_OUT" "powernode_system"
  assert_contains "core-only lock: FATAL names the remote" "$RUN_OUT" "../extensions/system/server"
  assert_contains "core-only lock: FATAL cites the task" "$RUN_OUT" "IMP-094d900f9093"

  rm -f "$LOCK"
}

echo "=== RED: a PATH section for the WRONG extension (remote doesn't match) ==="
{
  LOCK=$(mktemp)
  cat > "$LOCK" <<'EOF'
PATH
  remote: ../extensions/marketing/server
  specs:
    powernode_marketing (0.1.0)

GEM
  remote: https://rubygems.org/
  specs:
    rails (8.1.0)

DEPENDENCIES
  powernode_marketing!

BUNDLED WITH
   2.7.1
EOF

  run_cli --lock "$LOCK" --gem powernode_system --remote ../extensions/system/server

  assert_eq "wrong-extension lock: exit 1" "1" "$RUN_RC"
  assert_contains "wrong-extension lock: FATAL reported" "$RUN_OUT" "FATAL"

  rm -f "$LOCK"
}

echo "=== RED: the gem name only appears as a DEPENDENCY line, not inside the PATH specs (no false green) ==="
{
  LOCK=$(mktemp)
  cat > "$LOCK" <<'EOF'
GEM
  remote: https://rubygems.org/
  specs:
    rails (8.1.0)

DEPENDENCIES
  powernode_system!
  rails

BUNDLED WITH
   2.7.1
EOF

  run_cli --lock "$LOCK" --gem powernode_system --remote ../extensions/system/server

  assert_eq "gem name only in DEPENDENCIES: exit 1" "1" "$RUN_RC"

  rm -f "$LOCK"
}

echo "=== unit: --lock file does not exist — exit 2 (CLI misuse, not an assertion failure) ==="
{
  run_cli --lock /tmp/does-not-exist-$$.lock --gem powernode_system --remote ../extensions/system/server
  assert_eq "missing lock file: exit 2" "2" "$RUN_RC"
  assert_contains "missing lock file: names the path" "$RUN_OUT" "lock file not found"
}

echo "=== unit: --lock is required ==="
{
  run_cli --gem powernode_system --remote ../extensions/system/server
  assert_eq "no --lock: exit 2" "2" "$RUN_RC"
  assert_contains "no --lock: names the missing flag" "$RUN_OUT" "--lock is required"
}

echo "=== unit: --gem is required ==="
{
  LOCK=$(mktemp)
  echo "GEM" > "$LOCK"
  run_cli --lock "$LOCK" --remote ../extensions/system/server
  assert_eq "no --gem: exit 2" "2" "$RUN_RC"
  assert_contains "no --gem: names the missing flag" "$RUN_OUT" "--gem is required"
  rm -f "$LOCK"
}

echo "=== unit: --remote is required ==="
{
  LOCK=$(mktemp)
  echo "GEM" > "$LOCK"
  run_cli --lock "$LOCK" --gem powernode_system
  assert_eq "no --remote: exit 2" "2" "$RUN_RC"
  assert_contains "no --remote: names the missing flag" "$RUN_OUT" "--remote is required"
  rm -f "$LOCK"
}

echo ""
echo "=== summary: $PASS_COUNT passed, $FAIL_COUNT failed ==="
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
