#!/usr/bin/env bash
# test-compute-build-inputs-hash-build-scripts.sh — IMP-24d473c6f448.
#
# The build planner now targets a module whose stage15.sh arm (or a helper that
# arm calls) changed. The content-addressed skip must not defeat that: the hash
# only covered modules/<slug>/, so an arm-only change left it identical and the
# targeted build was skipped and re-tagged with the OLD digest.
#
# compute-build-inputs-hash.sh therefore folds the scripts/module-build tree
# into the hash of a module that has its OWN arm in stage15.sh's dispatch, and of
# no other module (a package-origin module must keep hashing exactly as before or
# it could never skip).
#
# Usage: bash tests/module-build/test-compute-build-inputs-hash-build-scripts.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_SH="${HASH_SH:-$TEST_DIR/../../scripts/module-build/compute-build-inputs-hash.sh}"
REAL_STAGE15="$TEST_DIR/../../scripts/module-build/stage15.sh"

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

mkdir -p "$REPO/modules/runtime-go" "$REPO/modules/hub-y" "$REPO/modules/redis" "$REPO/modules/go" "$REPO/scripts/module-build"
for m in runtime-go hub-y redis go; do echo "schema_version: 1" > "$REPO/modules/$m/manifest.yaml"; done
cat > "$REPO/scripts/module-build/stage15.sh" <<'SH'
case "$MODULE" in
  runtime-go)
    echo go
    ;;
  hub-x|hub-y)
    bash "$SCRIPT_DIR/helper.sh"
    ;;
esac
SH
echo "helper v1" > "$REPO/scripts/module-build/helper.sh"
echo "push v1" > "$REPO/scripts/module-build/push.sh"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
commit baseline

echo "compute-build-inputs-hash.sh: build scripts fold"
declare -A before
for m in runtime-go hub-y redis go; do before[$m]="$(hash_for --module "$m")"; done

echo "helper v2" > "$REPO/scripts/module-build/helper.sh"
commit "helper edit"
assert_ne "single-slug arm module: a build-script change moves the hash" "${before[runtime-go]}" "$(hash_for --module runtime-go)"
assert_ne "multi-slug arm module: a build-script change moves the hash"  "${before[hub-y]}"      "$(hash_for --module hub-y)"
assert_eq "module with NO arm keeps its hash (package-origin must still skip)" "${before[redis]}" "$(hash_for --module redis)"
assert_eq "a slug that is only a SUBSTRING of an arm's slug is not an arm"     "${before[go]}"    "$(hash_for --module go)"

after_helper="$(hash_for --module runtime-go)"
sed -i 's/echo go/echo go2/' "$REPO/scripts/module-build/stage15.sh"
commit "arm edit"
assert_ne "an edit inside the module's own arm moves the hash" "$after_helper" "$(hash_for --module runtime-go)"
assert_eq "module with NO arm still unchanged after an arm edit" "${before[redis]}" "$(hash_for --module redis)"

stable="$(hash_for --module runtime-go)"
git -C "$REPO" commit -q --allow-empty -m "unrelated commit"
assert_eq "an unrelated commit does not move an arm module's hash" "$stable" "$(hash_for --module runtime-go)"

echo "compute-build-inputs-hash.sh: no stage15.sh at the ref"
git -C "$REPO" rm -rq scripts && git -C "$REPO" commit -qm "drop scripts"
h_no_scripts="$(hash_for --module runtime-go)"
[ -n "$h_no_scripts" ] && ok "a ref with no scripts/module-build still hashes (no fold, no error)" || bad "hash failed with no scripts at the ref"

echo "compute-build-inputs-hash.sh: against the real stage15.sh"
mkdir -p "$REPO/scripts/module-build" "$REPO/modules/powernode-hub-worker" "$REPO/modules/postgres-primary"
cp "$REAL_STAGE15" "$REPO/scripts/module-build/stage15.sh"
echo "schema_version: 1" > "$REPO/modules/powernode-hub-worker/manifest.yaml"
echo "schema_version: 1" > "$REPO/modules/postgres-primary/manifest.yaml"
echo "helper v1" > "$REPO/scripts/module-build/some-helper.sh"
commit "real stage15"
real_arm="$(hash_for --module powernode-hub-worker)"
real_none="$(hash_for --module postgres-primary)"
echo "helper v2" > "$REPO/scripts/module-build/some-helper.sh"
commit "helper edit against real stage15"
assert_ne "real stage15: powernode-hub-worker (multi-slug needs_parent + own arm) folds the scripts" "$real_arm" "$(hash_for --module powernode-hub-worker)"
assert_eq "real stage15: a package-origin module (no arm) does not"                              "$real_none" "$(hash_for --module postgres-primary)"

echo
echo "passed=$PASS_COUNT failed=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
