#!/usr/bin/env bash
# test-stage-extension-system-files.sh — self-contained test suite for
# scripts/module-build/stage-extension-system-files.sh (IMP-fad0b3f67255).
#
# WHY THIS EXISTS: stage15.sh's powernode-extension-system arm shells out
# to this sibling script for the LOCAL, network-free half of its staging
# work — extracted specifically so this bug class (a runtime-required
# extension-root tree silently absent from the rsync source list, with the
# rsync itself exiting 0) is testable without stage15.sh's OTHER half (a
# hard-fail, no-fallback clone of the parent powernode-platform repo, plus
# a Vite frontend build), which needs network egress this test environment
# does not have.
#
# Same harness convention as test-derive-file-spec.sh: no bats dependency,
# plain bash + a small assert helper, subprocess invocation so a non-zero
# exit is observable without tripping this test's own strict mode.
#
# Usage: bash tests/module-build/test-stage-extension-system-files.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../../scripts/module-build/stage-extension-system-files.sh"

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

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    ok "$desc"
  else
    bad "$desc (expected file to exist: $path)"
  fi
}

assert_file_absent() {
  local desc="$1" path="$2"
  if [ ! -e "$path" ]; then
    ok "$desc"
  else
    bad "$desc (expected NOTHING at: $path)"
  fi
}

# Runs the script as a subprocess against a fresh --workspace/--fat-root
# pair, capturing combined stdout+stderr into $RUN_OUT and the exit code
# into $RUN_RC.
run_cli() {
  RUN_OUT=$(bash "$SCRIPT" "$@" 2>&1)
  RUN_RC=$?
}

# A minimal but REALISTIC workspace: real content under server/ (so the
# rsync has something to carry, matching the actual arm's behavior), a
# real config/runbooks.yml (the file this whole task is about), and a
# worker/ tree (required — the arm's other FATAL guard).
make_full_workspace() {
  local ws="$1"
  mkdir -p "$ws/server/app" "$ws/config" "$ws/worker/app/jobs" "$ws/worker/config"
  echo "# fixture" > "$ws/server/app/placeholder.rb"
  echo "system.fleet_rolling_upgrade: { not_documented: true, reason: fixture }" > "$ws/config/runbooks.yml"
  echo "# fixture job" > "$ws/worker/app/jobs/fixture_job.rb"
  echo "name: system_extension_system" > "$ws/extension.json"
}

echo "=== integration: full workspace (server/ + config/ + worker/ + extension.json) — GREEN ==="
{
  WS=$(mktemp -d)
  FAT=$(mktemp -d)
  make_full_workspace "$WS"

  run_cli --workspace "$WS" --fat-root "$FAT"

  assert_eq "full workspace: exit 0" "0" "$RUN_RC"
  assert_file_exists "ships server/ content" "$FAT/opt/powernode/extensions/system/server/app/placeholder.rb"
  assert_file_exists "ships extension.json" "$FAT/opt/powernode/extensions/system/extension.json"
  assert_file_exists "ships worker/ content" "$FAT/opt/powernode/extensions/system/worker/app/jobs/fixture_job.rb"
  # THE bug this task fixes: config/runbooks.yml must land in the staged
  # tree. Before the fix, this arm never rsynced config/ at all — the
  # rsync commands it DID run all exited 0, so this is the one assertion
  # that would have caught IMP-fad0b3f67255 before it ever reached a hub.
  assert_file_exists "ships config/runbooks.yml (IMP-fad0b3f67255)" "$FAT/opt/powernode/extensions/system/config/runbooks.yml"
  content=$(cat "$FAT/opt/powernode/extensions/system/config/runbooks.yml" 2>/dev/null)
  assert_contains "config/runbooks.yml content is the real fixture, not empty" "$content" "system.fleet_rolling_upgrade"

  rm -rf "$WS" "$FAT"
}

echo "=== unit: config/ missing from workspace — RED, exit 1, names config/ ==="
{
  WS=$(mktemp -d)
  FAT=$(mktemp -d)
  mkdir -p "$WS/server" "$WS/worker"
  # No config/ at all.

  run_cli --workspace "$WS" --fat-root "$FAT"

  assert_eq "missing config/: exit 1" "1" "$RUN_RC"
  assert_contains "missing config/: FATAL names config/" "$RUN_OUT" "FATAL"
  assert_contains "missing config/: message names config/ specifically" "$RUN_OUT" "config/ tree missing"
  assert_file_absent "missing config/: nothing staged at config/runbooks.yml" "$FAT/opt/powernode/extensions/system/config/runbooks.yml"

  rm -rf "$WS" "$FAT"
}

echo "=== unit: config/ present but EMPTY (no runbooks.yml inside it) — RED, the post-rsync check catches it ==="
{
  WS=$(mktemp -d)
  FAT=$(mktemp -d)
  mkdir -p "$WS/server" "$WS/worker" "$WS/config"
  # config/ exists (passes the [ -d config ] guard) but has no runbooks.yml
  # in it — the shape a future --exclude or manifest mask narrowing this
  # rsync could reintroduce without ever tripping the directory-existence
  # check above. This is what the SEPARATE post-rsync file check exists for.
  echo "unrelated" > "$WS/config/other-file.yml"

  run_cli --workspace "$WS" --fat-root "$FAT"

  assert_eq "empty config/: exit 1" "1" "$RUN_RC"
  assert_contains "empty config/: FATAL names runbooks.yml specifically" "$RUN_OUT" "config/runbooks.yml did not land"
  assert_file_exists "empty config/: the unrelated file DID still get rsynced" "$FAT/opt/powernode/extensions/system/config/other-file.yml"

  rm -rf "$WS" "$FAT"
}

echo "=== unit: worker/ missing from workspace — RED, exit 1 (pre-existing guard, unchanged) ==="
{
  WS=$(mktemp -d)
  FAT=$(mktemp -d)
  mkdir -p "$WS/server" "$WS/config"
  echo "kind: {}" > "$WS/config/runbooks.yml"
  # No worker/ at all.

  run_cli --workspace "$WS" --fat-root "$FAT"

  assert_eq "missing worker/: exit 1" "1" "$RUN_RC"
  assert_contains "missing worker/: FATAL names worker/" "$RUN_OUT" "worker/ tree missing"

  rm -rf "$WS" "$FAT"
}

echo "=== unit: --workspace is required ==="
{
  run_cli --fat-root /tmp/whatever
  assert_eq "no --workspace: exit 2" "2" "$RUN_RC"
  assert_contains "no --workspace: names the missing flag" "$RUN_OUT" "--workspace is required"
}

echo ""
echo "=== summary: $PASS_COUNT passed, $FAIL_COUNT failed ==="
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
