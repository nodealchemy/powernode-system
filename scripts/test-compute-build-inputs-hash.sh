#!/usr/bin/env bash
# test-compute-build-inputs-hash.sh — synthetic-fixture harness for
# compute-build-inputs-hash.sh. Mirrors the shape of
# test-ci-compute-dirty-closure.sh: build a throwaway git repo with known
# content, run the script, assert the hash moves exactly when content does.
#
# The property under test is the one the content-addressed build skip rests on:
#   hash is STABLE  <=> the shipped files would be identical
#   hash CHANGES    <=> some declared input changed
# A false "stable" reuses a stale artifact silently, so the negative cases
# (things that MUST change the hash) matter more than the positive ones.
#
# Usage: bash scripts/test-compute-build-inputs-hash.sh
# Exit codes: 0 = all pass, non-zero = failure count

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_SH="$SCRIPT_DIR/module-build/compute-build-inputs-hash.sh"
failures=0
tmproot=""

cleanup() { [ -n "$tmproot" ] && rm -rf "$tmproot"; }
trap cleanup EXIT

pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; failures=$((failures + 1)); }

assert_eq() {
  local expected="$1" actual="$2" what="$3"
  if [ "$expected" = "$actual" ]; then pass "$what"; else
    fail "$what (expected '$expected', got '$actual')"
  fi
}

assert_ne() {
  local a="$1" b="$2" what="$3"
  if [ "$a" != "$b" ]; then pass "$what"; else
    fail "$what (both were '$a' — hash did NOT change when it must)"
  fi
}

make_repo() {
  tmproot=$(mktemp -d)
  local r="$tmproot/repo"
  mkdir -p "$r/modules/redis/rootfs" "$r/modules/base-os/rootfs" "$r/server/app"
  echo "schema_version: 1" > "$r/modules/redis/manifest.yaml"
  echo "redis marker"      > "$r/modules/redis/rootfs/marker"
  echo "schema_version: 1" > "$r/modules/base-os/manifest.yaml"
  echo "core file"         > "$r/server/app/thing.rb"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name t
  git -C "$r" add -A
  git -C "$r" commit -qm baseline
  echo "$r"
}

hash_for() { bash "$HASH_SH" --repo "$REPO" "$@" 2>/dev/null; }

echo "compute-build-inputs-hash.sh"
REPO=$(make_repo)

# --- stability ---------------------------------------------------------------
h1=$(hash_for --module redis)
h2=$(hash_for --module redis)
assert_eq "$h1" "$h2" "same inputs -> same hash (deterministic)"

# The whole point: a DIFFERENT build sha must NOT move the hash, or nothing is
# ever skippable. This is what distinguishes it from the artifact digest.
git -C "$REPO" commit -q --allow-empty -m "unrelated commit"
h_after_unrelated=$(hash_for --module redis)
assert_eq "$h1" "$h_after_unrelated" "unrelated commit -> hash unchanged"

# --- sensitivity (the cases where a false 'unchanged' ships stale files) -----
echo "changed" > "$REPO/modules/redis/rootfs/marker"
git -C "$REPO" commit -qam "touch redis rootfs"
h_content=$(hash_for --module redis)
assert_ne "$h1" "$h_content" "module rootfs change -> hash changes"

echo "provides: [cache]" >> "$REPO/modules/redis/manifest.yaml"
git -C "$REPO" commit -qam "touch redis manifest"
h_manifest=$(hash_for --module redis)
assert_ne "$h_content" "$h_manifest" "module manifest change -> hash changes"

# --- isolation ---------------------------------------------------------------
echo "unrelated" > "$REPO/modules/base-os/rootfs/other"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "touch base-os"
h_isolated=$(hash_for --module redis)
assert_eq "$h_manifest" "$h_isolated" "another module's change -> hash unchanged"

# --- apt snapshot ------------------------------------------------------------
h_apt1=$(hash_for --module redis --apt-snapshot 20260101)
h_apt2=$(hash_for --module redis --apt-snapshot 20260202)
assert_ne "$h_apt1" "$h_apt2" "apt snapshot change -> hash changes"
assert_ne "$h_manifest" "$h_apt1" "adding an apt snapshot -> hash changes"

# --- declared extra inputs (the platform-module case) ------------------------
h_plat1=$(hash_for --module redis --input-path modules/redis --input-path server)
echo "core edit" > "$REPO/server/app/thing.rb"
git -C "$REPO" commit -qam "touch parent subtree"
h_plat2=$(hash_for --module redis --input-path modules/redis --input-path server)
assert_ne "$h_plat1" "$h_plat2" "declared parent subtree change -> hash changes"

# Order must not matter, or a caller reordering its arguments forces a rebuild.
h_order_a=$(hash_for --module redis --input-path modules/redis --input-path server)
h_order_b=$(hash_for --module redis --input-path server --input-path modules/redis)
assert_eq "$h_order_a" "$h_order_b" "input-path order -> hash unchanged"

# A parent-subtree edit must NOT move the hash when it was never declared —
# this is the documented sharp edge, pinned so it stays a known limit.
h_undeclared=$(hash_for --module redis)
echo "another core edit" > "$REPO/server/app/thing.rb"
git -C "$REPO" commit -qam "touch parent again"
assert_eq "$h_undeclared" "$(hash_for --module redis)" "UNDECLARED input change -> hash unchanged (known limit)"

# --- failure modes -----------------------------------------------------------
if bash "$HASH_SH" --repo "$REPO" --module redis --input-path modules/nope >/dev/null 2>&1; then
  fail "missing input path -> should exit non-zero"
else
  pass "missing input path -> errors instead of hashing empty"
fi

if bash "$HASH_SH" --repo "$REPO" >/dev/null 2>&1; then
  fail "missing --module -> should exit non-zero"
else
  pass "missing --module -> errors"
fi

# --- should-skip-build.sh fail-safe behaviour --------------------------------
# Only the SKIP direction can ship stale content, so every uncertain path must
# return BUILD. These assert that, without needing a registry.
SKIP_SH="$SCRIPT_DIR/module-build/should-skip-build.sh"

assert_builds() {
  local what="$1"; shift
  if bash "$SKIP_SH" "$@" >/dev/null 2>&1; then
    fail "$what (exited 0 = SKIP; must fail safe to BUILD)"
  else
    pass "$what"
  fi
}

echo
echo "should-skip-build.sh (fail-safe)"
assert_builds "no --module -> BUILD"                 --repo "$REPO"
assert_builds "unknown argument -> BUILD"            --module redis --bogus
assert_builds "uncomputable local hash -> BUILD"     --module redis --repo "$REPO" --input-path modules/nope
assert_builds "unreachable/absent registry -> BUILD" --module redis --repo "$REPO" \
  --registry 127.0.0.1:1 --owner nobody

# Self-protection: modules with out-of-tree inputs must refuse to skip when
# nothing was declared, so BUILD_SKIP_UNCHANGED=1 is safe to set globally.
for m in powernode-hub-backend powernode-hub-worker powernode-hub-frontend \
         powernode-extension-system powernode-system-base module-forge; do
  assert_builds "$m without declared inputs -> BUILD" --module "$m" --repo "$REPO"
done

# PATH stripped of oras: the tool being unavailable must not read as "skip".
if PATH=/nonexistent bash "$SKIP_SH" --module redis --repo "$REPO" >/dev/null 2>&1; then
  fail "oras missing -> BUILD (exited 0 = SKIP)"
else
  pass "oras missing -> BUILD"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$failures FAILURE(S)"
fi
exit "$failures"
