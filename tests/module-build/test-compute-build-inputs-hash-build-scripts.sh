#!/usr/bin/env bash
# test-compute-build-inputs-hash-build-scripts.sh — IMP-24d473c6f448.
#
# The build planner now targets a module whose stage15.sh arm (or a helper that
# arm calls) changed. The content-addressed skip must not defeat that: the hash
# only covered modules/<slug>/, so an arm-only change left it identical and the
# targeted build was skipped and re-tagged with the OLD digest.
#
# compute-build-inputs-hash.sh therefore folds in ONLY what stage15.sh gives that
# module: its own arm's text and the scripts/module-build helpers that arm calls
# (an earlier version folded the whole scripts tree, which invalidated every arm
# module on each of ~16 script commits a month). A module with NO arm hashes
# exactly as before, so a package-origin module keeps skipping.
#
# Usage: bash tests/module-build/test-compute-build-inputs-hash-build-scripts.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_SH="${HASH_SH:-$TEST_DIR/../../scripts/module-build/compute-build-inputs-hash.sh}"
REAL_STAGE15="$TEST_DIR/../../scripts/module-build/stage15.sh"
REAL_HELPER="$TEST_DIR/../../scripts/module-build/assert-gemfile-lock-has-extension-path.sh"

PASS_COUNT=0
FAIL_COUNT=0
ok()  { PASS_COUNT=$((PASS_COUNT + 1)); echo "  ok   - $1"; }
bad() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL - $1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (hash did NOT change: $2)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

hash_for() { bash "$HASH_SH" --repo "$REPO" "$@" 2>/dev/null; }
commit() { git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1"; }

mkdir -p "$REPO/modules/runtime-go" "$REPO/modules/hub-y" "$REPO/modules/vault" "$REPO/modules/redis" "$REPO/modules/go" "$REPO/scripts/module-build"
for m in runtime-go hub-y vault redis go; do echo "schema_version: 1" > "$REPO/modules/$m/manifest.yaml"; done
cat > "$REPO/scripts/module-build/stage15.sh" <<'SH'
echo shared preamble
case "$MODULE" in
  runtime-go)
    echo go
    ;;
  hub-x|hub-y)
    bash "$SCRIPT_DIR/helper.sh"
    # comment-only.sh is only mentioned here, never called
    ;;
  vault)
    bash "$SCRIPT_DIR/vault-helper.sh"
    ;;
esac
echo shared epilogue
SH
echo "helper v1" > "$REPO/scripts/module-build/helper.sh"
echo "vault-helper v1" > "$REPO/scripts/module-build/vault-helper.sh"
echo "comment-only v1" > "$REPO/scripts/module-build/comment-only.sh"
echo "push v1" > "$REPO/scripts/module-build/push.sh"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
commit baseline

MODULES="runtime-go hub-y vault redis go"
declare -A prev
snapshot() { for m in $MODULES; do prev[$m]="$(hash_for --module "$m")"; done; }
# expect_moved <what> <module>...   every listed module's hash changed, every other module's did not
expect_moved() {
  local what="$1"; shift
  local m moved
  for m in $MODULES; do
    moved=0; for x in "$@"; do [ "$x" = "$m" ] && moved=1; done
    if [ "$moved" = 1 ]; then assert_ne "$what: $m moves" "${prev[$m]}" "$(hash_for --module "$m")"
    else assert_eq "$what: $m unchanged" "${prev[$m]}" "$(hash_for --module "$m")"; fi
  done
}

echo "compute-build-inputs-hash.sh: arm-precise build-script fold"
snapshot
echo "helper v2" > "$REPO/scripts/module-build/helper.sh"; commit "helper edit"
expect_moved "helper called by the multi-slug arm" hub-y

snapshot
sed -i 's/echo go$/echo go2/' "$REPO/scripts/module-build/stage15.sh"; commit "runtime-go arm edit"
expect_moved "edit inside runtime-go's arm" runtime-go

snapshot
sed -i 's/hub-x|hub-y)/hub-x|hub-y|hub-z)/' "$REPO/scripts/module-build/stage15.sh"; commit "multi-slug arm pattern edit"
expect_moved "edit to the multi-slug arm's pattern line" hub-y

snapshot
sed -i 's/echo shared preamble/echo shared preamble 2/; s/echo shared epilogue/echo shared epilogue 2/' "$REPO/scripts/module-build/stage15.sh"; commit "shared code outside every arm"
expect_moved "shared code outside every arm (called by no arm)"

snapshot
echo "push v2" > "$REPO/scripts/module-build/push.sh"; commit "helper no arm calls"
expect_moved "a script no arm calls"

snapshot
echo "comment-only v2" > "$REPO/scripts/module-build/comment-only.sh"; commit "helper only mentioned in a comment"
expect_moved "a script only mentioned in an arm comment"

snapshot
echo "vault-helper v2" > "$REPO/scripts/module-build/vault-helper.sh"; commit "vault helper"
expect_moved "helper called by vault's arm" vault

snapshot
git -C "$REPO" commit -q --allow-empty -m "unrelated commit"
expect_moved "an unrelated commit"

echo "compute-build-inputs-hash.sh: no stage15.sh at the ref"
git -C "$REPO" rm -rq scripts && git -C "$REPO" commit -qm "drop scripts"
h_no_scripts="$(hash_for --module runtime-go)"
[ -n "$h_no_scripts" ] && ok "a ref with no scripts/module-build still hashes (no fold, no error)" || bad "hash failed with no scripts at the ref"

echo "compute-build-inputs-hash.sh: an unreadable stage15.sh fails the hash (the skip then reads BUILD)"
mkdir -p "$REPO/scripts/module-build"
echo "no dispatch here" > "$REPO/scripts/module-build/stage15.sh"; commit "broken stage15"
if bash "$HASH_SH" --repo "$REPO" --module runtime-go >/dev/null 2>&1; then bad "unparseable stage15.sh -> should exit non-zero"; else ok "unparseable stage15.sh -> errors instead of hashing without the arm"; fi

echo "compute-build-inputs-hash.sh: against the real stage15.sh"
cp "$REAL_STAGE15" "$REPO/scripts/module-build/stage15.sh"
cp "$REAL_HELPER" "$REPO/scripts/module-build/$(basename "$REAL_HELPER")"
mkdir -p "$REPO/modules/powernode-hub-worker" "$REPO/modules/powernode-hub-backend" "$REPO/modules/postgres-primary"
for m in powernode-hub-worker powernode-hub-backend postgres-primary; do echo "schema_version: 1" > "$REPO/modules/$m/manifest.yaml"; done
commit "real stage15"
MODULES="powernode-hub-worker powernode-hub-backend postgres-primary vault"
snapshot
echo "# edited" >> "$REPO/scripts/module-build/$(basename "$REAL_HELPER")"; commit "helper edit against real stage15"
# stage-extension-system-files.sh is called by the hub-backend and extension-system arms only
expect_moved "real stage15, helper called by hub-backend" powernode-hub-backend
echo
echo "passed=$PASS_COUNT failed=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
