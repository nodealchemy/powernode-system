#!/usr/bin/env bash
# test-should-skip-build-declared-inputs.sh — regression test for the
# extension-system wrong-SKIP bug found while investigating IMP-fad0b3f67255
# (config/ never shipped): batch 01a0e546 (range 468ec756..e9a440c7, the very
# commit that added config/ staging) published v131 with an OCI digest
# BYTE-IDENTICAL to v130 — the digest that predates the fix. Per
# compute-build-inputs-hash.sh's own measured claim (187/187 distinct digests
# across real rebuilds, because stage2-carve stamps BUILD_SHA into
# SOURCE_DATE_EPOCH/EROFS_UUID), an identical digest is possible ONLY if the
# build was SKIPPED, never actually run — a genuine rebuild at a new sha
# cannot reproduce old bytes by construction.
#
# ROOT CAUSE: compute-build-inputs-hash.sh defaults to hashing only
# modules/<slug>/ (here: modules/powernode-extension-system). powernode-
# extension-system's REAL build inputs — server/, config/, worker/,
# extension.json, and the staging scripts that decide how they're carved
# (scripts/module-build/stage15.sh, stage-extension-system-files.sh) — live
# at the REPO ROOT, entirely outside modules/powernode-extension-system/, and
# nothing in this pipeline ever sets BUILD_INPUT_PATHS to declare them (grep
# scripts/ .gitea/ for BUILD_INPUT_PATHS= — zero assignment sites, only
# reads). needs-parent-modules.sh lists powernode-extension-system in
# module_needs_parent() (it clones the parent repo for its SEPARATE
# dedicated-module frontend build), which is exactly why should-skip-build.sh
# excluded it from NEEDS_DECLARED_INPUTS — but folding in --core-ref only
# covers the parent-repo subtree a needs-parent module packages; it says
# nothing about extension-system's OWN local, same-repo payload. So a batch
# whose core ref and modules/powernode-extension-system/ tree are both
# unchanged (true of 01a0e546: it only touched scripts/module-build/*, never
# modules/powernode-extension-system/) hashes identically to the last
# published artifact and gets silently re-tagged, no matter what actually
# changed in server/, config/, or worker/.
#
# THE TWO GUARDS ARE INDEPENDENT, NOT MUTUALLY EXCLUSIVE (verified by reading
# should-skip-build.sh, not assumed): the NEEDS_DECLARED_INPUTS refusal and
# the module_needs_parent/--core-ref refusal are two separate `if` blocks: the
# first checks HASH_ARGS (from --input-path), the second checks CORE_REF_ARG,
# and core_ref_hash_args() folds --core-ref into the hash unconditionally once
# module_needs_parent() is true — completely independent of whether the module
# is ALSO in NEEDS_DECLARED_INPUTS. Adding powernode-extension-system to
# NEEDS_DECLARED_INPUTS does not disable, bypass, or race the core-ref fold.
#
# THE FIX (this task): add powernode-extension-system to
# NEEDS_DECLARED_INPUTS, matching how its two existing siblings
# (powernode-system-base, module-forge) already behave — nothing currently
# sets BUILD_INPUT_PATHS for any of them, so all three simply always refuse
# to skip (fail SAFE, exactly the documented direction: "a wrong BUILD costs
# one rebuild, a wrong SKIP silently ships a stale module") until a future
# change threads real --input-path declarations through for it.
#
# This test never touches a real registry: it stubs `oras` on PATH so the
# script's `oras manifest fetch` returns a canned manifest whose
# org.powernode.build-inputs-sha256 annotation is made to EXACTLY equal what
# compute-build-inputs-hash.sh computes for the (unchanged)
# modules/powernode-extension-system tree + a fixed --core-ref — i.e., it
# reproduces the real published-artifact shape from the incident, not an
# arbitrary fixture.
#
# Usage: bash tests/module-build/test-should-skip-build-declared-inputs.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_BUILD_DIR="$TEST_DIR/../../scripts/module-build"
SCRIPT="$MODULE_BUILD_DIR/should-skip-build.sh"
HASH_SCRIPT="$MODULE_BUILD_DIR/compute-build-inputs-hash.sh"

PASS_COUNT=0
FAIL_COUNT=0

ok()  { PASS_COUNT=$((PASS_COUNT + 1)); echo "  ok   - $1"; }
bad() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL - $1"; }

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

MODULE=powernode-extension-system
CORE_REF_FIXTURE=deadbeefcafef00ddeadbeefcafef00ddeadbeef
REGISTRY=git.powernode.org
OWNER=powernode
TAG=latest

# --- fixture repo: a git checkout carrying an (unchanged-by-this-test)
# modules/powernode-extension-system/ tree, the same shape should-skip-build.sh
# defaults to hashing when nothing declares --input-path. -------------------
REPO=$(mktemp -d)
STUB_BIN=$(mktemp -d)
git -C "$REPO" init --quiet -b main
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name "test"
mkdir -p "$REPO/modules/$MODULE"
echo "name: $MODULE" > "$REPO/modules/$MODULE/manifest.yaml"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "fixture: modules/$MODULE tree"

# The published artifact's recorded hash, reproduced via the SAME code path
# should-skip-build.sh itself uses (default input path + --core-ref folded in
# for a needs-parent module) — this is what makes the fixture faithful to the
# real incident rather than an arbitrary planted value.
PUBLISHED_HASH=$(bash "$HASH_SCRIPT" --module "$MODULE" --repo "$REPO" --ref HEAD --core-ref "$CORE_REF_FIXTURE")
[ -n "$PUBLISHED_HASH" ] || { echo "FIXTURE SETUP FAILED: could not compute published hash" >&2; exit 2; }

# --- stub oras: answers `oras manifest fetch <registry>/<owner>/<module>:<tag>`
# with a manifest carrying that exact annotation. Anything else is an error —
# this test does not expect should-skip-build.sh to call oras any other way.
cat > "$STUB_BIN/oras" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "manifest" ] && [ "\$2" = "fetch" ] && [ "\$3" = "$REGISTRY/$OWNER/$MODULE:$TAG" ]; then
  printf '{"annotations":{"org.powernode.build-inputs-sha256":"$PUBLISHED_HASH"}}\n'
  exit 0
fi
echo "stub oras: unexpected invocation: \$*" >&2
exit 1
EOF
chmod +x "$STUB_BIN/oras"

run_skip_check() {
  RUN_OUT=$(PATH="$STUB_BIN:$PATH" CORE_REF="$CORE_REF_FIXTURE" \
    bash "$SCRIPT" --module "$MODULE" --repo "$REPO" --ref HEAD \
    --registry "$REGISTRY" --owner "$OWNER" --tag "$TAG" 2>&1)
  RUN_RC=$?
}

echo "=== regression: powernode-extension-system with unchanged modules/<slug> tree + unchanged core-ref ==="
{
  run_skip_check
  # THE FIX under test. Before it, NEEDS_DECLARED_INPUTS omitted
  # powernode-extension-system, the local hash matched the stub's published
  # hash exactly (both computed the same way), and this exited 0 (SKIP) —
  # reproducing the real incident where v131 published v130's untouched,
  # config/-less digest. After the fix, this must refuse to skip.
  assert_eq "refuses to skip (exit 1 = BUILD, never SKIP)" "1" "$RUN_RC"
  assert_contains "names the module and the real reason (undeclared inputs)" "$RUN_OUT" "reads inputs outside modules/$MODULE/ and none were declared"
  # Never reaches the registry at all — the NEEDS_DECLARED_INPUTS refusal is
  # the FIRST check in the script, before the module_needs_parent/core-ref
  # check and before any oras call.
  assert_contains "-> BUILD is the decision logged" "$RUN_OUT" "-> BUILD"
}

echo "=== the core-ref fold is untouched: declaring --input-path still requires --core-ref for this module ==="
{
  RUN_OUT=$(PATH="$STUB_BIN:$PATH" bash "$SCRIPT" --module "$MODULE" --repo "$REPO" --ref HEAD \
    --input-path "modules/$MODULE" --input-path server --input-path config --input-path worker \
    --registry "$REGISTRY" --owner "$OWNER" --tag "$TAG" 2>&1)
  RUN_RC=$?
  # Declaring --input-path bypasses the NEEDS_DECLARED_INPUTS refusal (proven
  # by getting a DIFFERENT refusal reason below), but powernode-extension-system
  # is STILL a needs_parent module, so it separately refuses without a
  # --core-ref — proving the two guards are independent, not one replacing the
  # other, exactly as this fix's design note claims.
  assert_eq "declared inputs but no core-ref: still refuses (exit 1)" "1" "$RUN_RC"
  assert_contains "different reason this time: the needs-parent/core-ref guard, not the declared-inputs one" "$RUN_OUT" "packages parent-repo content and no --core-ref/CORE_REF was supplied"
}

echo "=== sibling modules already in NEEDS_DECLARED_INPUTS are unaffected (no regression) ==="
{
  for sibling in powernode-system-base module-forge; do
    mkdir -p "$REPO/modules/$sibling"
    echo "name: $sibling" > "$REPO/modules/$sibling/manifest.yaml"
  done
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "fixture: sibling module trees"

  for sibling in powernode-system-base module-forge; do
    RUN_OUT=$(PATH="$STUB_BIN:$PATH" bash "$SCRIPT" --module "$sibling" --repo "$REPO" --ref HEAD \
      --registry "$REGISTRY" --owner "$OWNER" --tag "$TAG" 2>&1)
    RUN_RC=$?
    assert_eq "$sibling: still refuses to skip (exit 1)" "1" "$RUN_RC"
    assert_contains "$sibling: still the declared-inputs reason" "$RUN_OUT" "reads inputs outside modules/$sibling/ and none were declared"
  done
}

rm -rf "$REPO" "$STUB_BIN"

echo ""
echo "=== summary: $PASS_COUNT passed, $FAIL_COUNT failed ==="
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
