#!/usr/bin/env bash
# test-hash-failure-warning.sh — IMP-24d473c6f448 (round 2, R2-1).
#
# compute-build-inputs-hash.sh now FAILS when it cannot read stage15.sh's arm for
# a module (python3 missing, an unparseable dispatch). should-skip-build.sh and
# push.sh both sent its stderr to /dev/null, so that failure looked like an
# ordinary BUILD / empty hash and silently turned the skip off for every module.
# Both must now say which module fell back and why.
#
# Usage: bash tests/module-build/test-hash-failure-warning.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_BUILD_DIR="${MODULE_BUILD_DIR:-$TEST_DIR/../../scripts/module-build}"

PASS_COUNT=0
FAIL_COUNT=0
ok()  { PASS_COUNT=$((PASS_COUNT + 1)); echo "  ok   - $1"; }
bad() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL - $1"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (expected [$3] in: $2)" ;; esac; }

MODULE="warnfixture-$$"
TMP="$(mktemp -d)"
REPO="$TMP/repo"
STUB_BIN="$TMP/bin"
trap 'rm -rf "$TMP" "/tmp/$MODULE.packages.txt" "/tmp/$MODULE.erofs" "/tmp/$MODULE.erofs.meta"' EXIT

mkdir -p "$REPO/modules/$MODULE" "$REPO/scripts/module-build" "$STUB_BIN"
echo "name: $MODULE" > "$REPO/modules/$MODULE/manifest.yaml"
# No module dispatch at all: stage15-arm.py exits 2, so the hash script FAILS.
echo "echo no dispatch here" > "$REPO/scripts/module-build/stage15.sh"
git -C "$REPO" init --quiet -b main
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m fixture
echo "pkg" > "/tmp/$MODULE.packages.txt"

# oras: login succeeds; anything else fails, which stops push.sh right after the
# hash step this test is about.
cat > "$STUB_BIN/oras" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "login" ] && exit 0
echo "stub oras: $*" >&2
exit 1
STUB
chmod +x "$STUB_BIN/oras"

echo "should-skip-build.sh: hash script failure is surfaced"
out=$(PATH="$STUB_BIN:$PATH" bash "$MODULE_BUILD_DIR/should-skip-build.sh" --module "$MODULE" --repo "$REPO" --ref HEAD 2>&1)
rc=$?
[ "$rc" = 1 ] && ok "falls back to BUILD (exit 1)" || bad "expected exit 1, got $rc"
assert_contains "names the module" "$out" "inputs hash failed for $MODULE"
assert_contains "says it fell back to BUILD" "$out" "falling back to BUILD"
assert_contains "carries the hash script's reason" "$out" "unparseable dispatch"

echo "push.sh: hash script failure is surfaced"
out=$(cd "$REPO" && PATH="$STUB_BIN:$PATH" ORAS_REGISTRY_USERNAME=u ORAS_REGISTRY_PASSWORD=p \
  bash "$MODULE_BUILD_DIR/push.sh" --module "$MODULE" --sha deadbeef --workspace "$REPO" --tag t 2>&1)
assert_contains "names the module" "$out" "build-inputs hash failed for $MODULE"
assert_contains "says the next build cannot skip" "$out" "cannot skip"
assert_contains "carries the hash script's reason" "$out" "unparseable dispatch"

echo
echo "passed=$PASS_COUNT failed=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
