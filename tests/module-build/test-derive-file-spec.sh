#!/usr/bin/env bash
# test-derive-file-spec.sh — self-contained test suite for
# scripts/module-build/derive-file-spec.sh. No bats dependency (not
# available in this repo's CI containers today — see the script's own
# header); plain bash + a small assert harness.
#
# Two layers:
#   1. Unit tests — source derive-file-spec.sh and call its pure functions
#      (owned_package_names, apply_carve_waivers, build_rsync_carve_filter,
#      rootfs_files) directly against small inline fixtures. No fat
#      tree / dpkg admindir needed for these.
#   2. Integration tests — invoke the script's `derive` / `conformance`
#      CLI as a subprocess against the fixture package-lists + fixture
#      dpkg admindir trees + fixture manifest workspace under
#      fixtures/{packages,fat,workspace}/. Exercises the full
#      derive-package-ownership -> carve-via-rsync -> diff -> waiver path
#      end to end, without any mmdebstrap/dpkg build.
#
# Fixture scenarios (see fixtures/workspace/modules/*/manifest.yaml):
#   good-module         file_spec exactly matches demo-svc's owned files
#                        -> PASS, over=0, under=0
#   bad-module           file_spec also claims /etc/passwd (owned by
#                        base-files, not this module)
#                        -> FAIL (over-inclusion), exit 1 [the RED case]
#   undercarve-module    file_spec claims only part of demo-svc's files,
#                        no waiver -> WARN (unwaived under-carve), exit 0
#   waived-module        same under-carve, but waived via carve_waivers
#                        -> exit 0, zero unwaived
#   rootfs-module         file_spec claims a path owned by NO package but
#                        shipped via this module's own rootfs/ overlay
#                        -> PASS (rootfs/ exclusion), exit 0
#   base-os-stray         module IS the base-module; claims a stray
#                        unowned file -> over-inclusion present but
#                        WARN-only (exempt), exit 0
#
# Usage: bash tests/module-build/test-derive-file-spec.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail
# (deliberately NOT -e: a failed assertion must not abort the remaining
# test cases — see assert_* below, which record failures instead of
# exiting.)

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$TEST_DIR/fixtures"
SCRIPT="$TEST_DIR/../../scripts/module-build/derive-file-spec.sh"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck source=scripts/module-build/derive-file-spec.sh
source "$SCRIPT"
# derive-file-spec.sh runs `set -euo pipefail` at its own top; `source`
# (unlike running it as a subprocess) executes in THIS shell, so that `-e`
# silently leaks in here too — the first captured non-zero RUN_RC below
# would then abort the whole suite instead of being recorded as a normal
# assertion. Turn -e back off; this harness relies on assert_* recording
# failures rather than the shell aborting on them.
set +e

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

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) bad "$desc (expected output to NOT contain [$needle])" ;;
    *) ok "$desc" ;;
  esac
}

# Runs the script as a subprocess (so a non-zero exit from `conformance`
# can be observed without tripping this test script's own strict mode)
# and captures combined stdout+stderr into $RUN_OUT and the exit code
# into $RUN_RC.
run_cli() {
  RUN_OUT=$(bash "$SCRIPT" "$@" 2>&1)
  RUN_RC=$?
}

echo "=== unit: owned_package_names ==="
{
  pkgf=$(mktemp); basef=$(mktemp)
  printf 'bash\t1\tamd64\nbase-files\t1\tamd64\ndemo-svc\t1\tamd64\n' > "$pkgf"
  printf 'bash\t1\tamd64\nbase-files\t1\tamd64\n' > "$basef"
  got=$(owned_package_names "$pkgf" "$basef" | tr '\n' ',')
  assert_eq "owned_package_names: module-only package survives the diff" "demo-svc," "$got"
  rm -f "$pkgf" "$basef"
}

echo "=== unit: apply_carve_waivers ==="
{
  underf=$(mktemp); waiversf=$(mktemp); outf=$(mktemp)
  printf '/etc/demo-svc/config.yaml\n/lib/systemd/system/demo-svc.service\n/etc/unrelated.conf\n' > "$underf"
  printf '/etc/demo-svc/**\n/lib/systemd/system/demo-svc.service\n' > "$waiversf"
  apply_carve_waivers "$underf" "$waiversf" "$outf"
  got=$(tr '\n' ',' < "$outf")
  assert_eq "apply_carve_waivers: waived globs dropped, unwaived path survives" "/etc/unrelated.conf," "$got"
  rm -f "$underf" "$waiversf" "$outf"
}

echo "=== unit: build_rsync_carve_filter ==="
{
  maskf=$(mktemp); fsf=$(mktemp); psf=$(mktemp); outf=$(mktemp)
  printf '/var/**\n' > "$maskf"
  printf '/etc/**\n' > "$fsf"
  printf '/etc/shadow\n' > "$psf"
  build_rsync_carve_filter "$maskf" "$fsf" "$psf" "$outf"
  expected=$'- /var/**\n+ /etc/**\n+ /etc/shadow\n- *'
  got=$(cat "$outf")
  assert_eq "build_rsync_carve_filter: mask as -, file_spec/protected_spec as +, trailing - *" "$expected" "$got"
  rm -f "$maskf" "$fsf" "$psf" "$outf"
}

echo "=== unit: rootfs_files ==="
{
  got=$(rootfs_files "$FIX/workspace" "rootfs-module" | tr '\n' ',')
  assert_eq "rootfs_files: lists rootfs/ overlay content as an absolute path" "/etc/custom-app.conf," "$got"
  got_empty=$(rootfs_files "$FIX/workspace" "good-module" | tr '\n' ',')
  assert_eq "rootfs_files: empty for a module with no rootfs/ dir" "" "$got_empty"
}

echo "=== integration: derive (good-module) ==="
{
  run_cli derive --module good-module --fat-root "$FIX/fat/demo" --packages-dir "$FIX/packages"
  assert_eq "derive good-module: exit 0" "0" "$RUN_RC"
  expected=$'/etc/demo-svc/config.yaml\n/lib/systemd/system/demo-svc.service\n/usr/bin/demo-svc'
  assert_eq "derive good-module: owned-file list matches demo-svc's dpkg -L output (dirs dropped)" "$expected" "$RUN_OUT"
}

echo "=== integration: conformance (good-module — exact match) ==="
{
  run_cli conformance --module good-module --workspace "$FIX/workspace" --fat-root "$FIX/fat/demo" --packages-dir "$FIX/packages"
  assert_eq "conformance good-module: exit 0 (PASS)" "0" "$RUN_RC"
  assert_contains "conformance good-module: reports RESULT: PASS" "$RUN_OUT" "RESULT: PASS"
  assert_contains "conformance good-module: over-inclusion 0" "$RUN_OUT" "over-inclusion (carved, not owned, not rootfs/):        0 files"
}

echo "=== integration: conformance (bad-module — RED case, over-inclusion) ==="
{
  run_cli conformance --module bad-module --workspace "$FIX/workspace" --fat-root "$FIX/fat/demo" --packages-dir "$FIX/packages"
  assert_eq "conformance bad-module: exit 1 (FAIL)" "1" "$RUN_RC"
  assert_contains "conformance bad-module: reports FAIL" "$RUN_OUT" "FAIL:"
  assert_contains "conformance bad-module: names the offending path" "$RUN_OUT" "/etc/passwd"
}

echo "=== integration: conformance (undercarve-module — WARN, unwaived) ==="
{
  run_cli conformance --module undercarve-module --workspace "$FIX/workspace" --fat-root "$FIX/fat/demo" --packages-dir "$FIX/packages"
  assert_eq "conformance undercarve-module: exit 0 (WARN is non-blocking)" "0" "$RUN_RC"
  assert_contains "conformance undercarve-module: reports WARN" "$RUN_OUT" "WARN: 2 owned file(s) not carved"
  assert_contains "conformance undercarve-module: still RESULT: PASS" "$RUN_OUT" "RESULT: PASS"
}

echo "=== integration: conformance (waived-module — WARN suppressed) ==="
{
  run_cli conformance --module waived-module --workspace "$FIX/workspace" --fat-root "$FIX/fat/demo" --packages-dir "$FIX/packages"
  assert_eq "conformance waived-module: exit 0" "0" "$RUN_RC"
  assert_not_contains "conformance waived-module: no WARN (fully waived)" "$RUN_OUT" "WARN:"
  assert_contains "conformance waived-module: under-carve count still reported (2, 0 unwaived)" "$RUN_OUT" "under-carve (owned, not carved):                        2 files (0 unwaived)"
}

echo "=== integration: conformance (rootfs-module — rootfs/ exclusion) ==="
{
  run_cli conformance --module rootfs-module --workspace "$FIX/workspace" --fat-root "$FIX/fat/demo" --packages-dir "$FIX/packages"
  assert_eq "conformance rootfs-module: exit 0 (rootfs/ content excluded from FAIL)" "0" "$RUN_RC"
  assert_contains "conformance rootfs-module: over-inclusion 0" "$RUN_OUT" "over-inclusion (carved, not owned, not rootfs/):        0 files"
}

echo "=== integration: conformance (base-os-stray — base-module exemption) ==="
{
  run_cli conformance --module base-os-stray --workspace "$FIX/workspace" --fat-root "$FIX/fat/base-os-stray" --packages-dir "$FIX/packages" --base-module base-os-stray
  assert_eq "conformance base-os-stray: exit 0 (over-inclusion is WARN-only for the base module)" "0" "$RUN_RC"
  assert_contains "conformance base-os-stray: exemption note printed" "$RUN_OUT" "exempt by design"
  assert_contains "conformance base-os-stray: still surfaces the over-inclusion as WARN" "$RUN_OUT" "WARN: over-inclusion"
  assert_contains "conformance base-os-stray: RESULT: PASS despite the WARN" "$RUN_OUT" "RESULT: PASS"
}

echo ""
echo "=== summary: $PASS_COUNT passed, $FAIL_COUNT failed ==="
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
