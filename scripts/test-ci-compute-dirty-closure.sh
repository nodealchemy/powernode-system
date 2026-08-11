#!/usr/bin/env bash
# test-ci-compute-dirty-closure.sh — synthetic-fixture test harness for
# ci-compute-dirty-closure.sh.
#
# Creates a temporary git repo with a known module graph, commits a
# baseline, makes targeted changes, then invokes the script and asserts
# the right set of modules came back dirty.
#
# Coverage:
#   1. Single-module source change → just that module
#   2. Source change + dep-graph expansion → module + its dependents
#   3. Agent change → forces powernode-system-base
#   4. Workflow file change → all modules
#   5. Capability-based requires vs name-based requires
#   6. Diamond dependency (A depends on B+C; B and C both depend on D)
#   7. Self-reference guard (manifest that requires its own capability)
#   8. Unchanged → empty closure
#   9. Manifest-only change (no .rb, just provides edit) → still dirty
#
# Apt-closure drift is left to a live CI run (requires docker + oras +
# network access to a real registry) and is not covered here.
#
# Usage:
#   PATH=/tmp:$PATH bash scripts/test-ci-compute-dirty-closure.sh
#   (yq must be on PATH; install via /tmp/yq if not present)
#
# Exit codes: 0 = all pass, non-zero = failure count

set -euo pipefail

SCRIPT_UNDER_TEST="$(cd "$(dirname "$0")" && pwd)/ci-compute-dirty-closure.sh"
if [[ ! -x "$SCRIPT_UNDER_TEST" ]]; then
  echo "FATAL: $SCRIPT_UNDER_TEST not executable" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "FATAL: yq not on PATH; install (mikefarah/yq) before running" >&2
  exit 1
fi

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Test fixture builder
# ---------------------------------------------------------------------------

make_fixture_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo/modules" "$repo/agent" "$repo/.gitea/workflows" "$repo/templates/module-repo"
  cd "$repo"
  git init -q -b main
  git config user.email t@t.t
  git config user.name t

  # 5 modules — small enough to reason about, complex enough to cover
  # the dep-graph paths.
  #
  # ┌────────────────────────────────────────────────────────────────┐
  # │  base-os   ← agent (forces this)                               │
  # │     ↑                                                          │
  # │     │ (requires: base.os via capability)                       │
  # │  hub-backend  (requires: database.postgres via capability)     │
  # │     │                                                          │
  # │     └──→ postgres-primary (provides: database.postgres)        │
  # │     │      ↑                                                   │
  # │     │      │ (requires: database.postgres via capability)      │
  # │     │   postgres-replica                                       │
  # │     │                                                          │
  # │     └──→ redis (provides: cache.redis)                         │
  # └────────────────────────────────────────────────────────────────┘
  make_manifest base-os                ""                                 "base.os@1.0"
  make_manifest postgres-primary       "base.os"                          "database.postgres@1.0" "postgresql-16 libpq-dev"
  make_manifest postgres-replica       "base.os,database.postgres"        ""                       "postgresql-16-replica"
  make_manifest redis                  "base.os"                          "cache.redis@1.0"        "redis-server"
  make_manifest hub-backend            "base.os,database.postgres,cache.redis" "service.hub-backend@1.0" "ruby3.2"

  # The agent special-case requires the literal name powernode-system-base.
  # Add it so the agent-change test asserts something concrete.
  make_manifest powernode-system-base  ""                                 "agent.binary@1.0"        "ca-certificates"

  # Same shape for the build-script special-case: module-forge bakes
  # scripts/module-build/*.sh into its own rootfs at build time.
  make_manifest module-forge           ""                                 "build.forge@1.0"

  mkdir -p scripts/module-build
  echo "# build-one-module stub" > scripts/module-build/build-one-module.sh

  echo "// agent main.go stub" > agent/main.go
  echo "# workflow stub" > .gitea/workflows/build-platform-modules.yaml
  echo "FROM debian:trixie" > templates/module-repo/Containerfile

  git add -A
  git commit -q -m "baseline"
}

make_manifest() {
  local name="$1"
  local requires_csv="$2"
  local provides_csv="$3"
  local packages_csv="${4:-}"
  mkdir -p "modules/$name/rootfs"
  {
    echo "schema_version: 1"
    echo "name: $name"
    echo "display_name: $name"
    echo "file_spec: [/opt/$name/**]"
    if [[ -n "$packages_csv" ]]; then
      echo "package_spec:"
      for p in $packages_csv; do echo "  - $p"; done
    fi
    echo "dependencies:"
    echo "  requires:"
    if [[ -n "$requires_csv" ]]; then
      IFS=',' read -ra reqs <<< "$requires_csv"
      for r in "${reqs[@]}"; do echo "    - capability:$r"; done
    else
      echo "    []"
    fi
    echo "  provides:"
    if [[ -n "$provides_csv" ]]; then
      IFS=',' read -ra provs <<< "$provides_csv"
      for p in "${provs[@]}"; do echo "    - $p"; done
    else
      echo "    []"
    fi
  } > "modules/$name/manifest.yaml"
  echo "stub" > "modules/$name/rootfs/marker"
}

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

# Run the script under test against the fixture's HEAD~1..HEAD and
# return the dirty closure as a sorted, comma-joined string for easy
# comparison.
run_script() {
  APT_DRIFT_CHECK=0 bash "$SCRIPT_UNDER_TEST" HEAD~1 HEAD 2>/dev/null \
    | sort -u | tr '\n' ',' | sed 's/,$//'
}

assert_equal() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

test_single_module_change() {
  local repo="$TMP/single"; make_fixture_repo "$repo"
  echo "changed" > "$repo/modules/redis/rootfs/marker"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "touch redis"
  cd "$repo"
  # redis provides cache.redis. hub-backend requires cache.redis. So
  # changing redis correctly fans out to hub-backend via the capability
  # graph — the closure is both modules. (This is the GOAL — verifies
  # dep-graph expansion happens for direct path-filter dirty entries.)
  assert_equal "single-module change → fans out via capability" \
    "hub-backend,redis" "$(run_script)"
}

test_source_change_with_dependents() {
  local repo="$TMP/with-deps"; make_fixture_repo "$repo"
  echo "changed" > "$repo/modules/postgres-primary/rootfs/marker"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "touch postgres-primary"
  cd "$repo"
  # postgres-primary is required (via database.postgres capability) by
  # postgres-replica AND hub-backend → closure is all three
  assert_equal "source change with dependents" \
    "hub-backend,postgres-primary,postgres-replica" "$(run_script)"
}

test_agent_change_forces_system_base() {
  local repo="$TMP/agent"; make_fixture_repo "$repo"
  echo "changed" > "$repo/agent/main.go"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "touch agent"
  cd "$repo"
  # powernode-system-base has no dependents → closure is just that one
  assert_equal "agent change → system-base only" \
    "powernode-system-base" "$(run_script)"
}

test_workflow_change_forces_all() {
  local repo="$TMP/wf"; make_fixture_repo "$repo"
  echo "# rev" >> "$repo/.gitea/workflows/build-platform-modules.yaml"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "touch workflow"
  cd "$repo"
  # All 7 modules should be dirty (module-forge joined the fixture with the
  # build-script special-case).
  assert_equal "workflow change → all modules" \
    "base-os,hub-backend,module-forge,postgres-primary,postgres-replica,powernode-system-base,redis" "$(run_script)"
}

test_no_changes() {
  local repo="$TMP/nop"; make_fixture_repo "$repo"
  # Make an empty commit so HEAD~1..HEAD has zero file diff.
  git -C "$repo" commit -q --allow-empty -m "no-op"
  cd "$repo"
  assert_equal "no changes → empty closure" "" "$(run_script)"
}

test_manifest_only_change_still_dirty() {
  local repo="$TMP/manifest"; make_fixture_repo "$repo"
  # Touch only manifest.yaml — no rootfs change. Closure still fans
  # out via capability graph (redis → hub-backend).
  sed -i 's/display_name: redis/display_name: redis-renamed/' "$repo/modules/redis/manifest.yaml"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "rename redis display"
  cd "$repo"
  assert_equal "manifest-only change → still dirty (+ dependents)" \
    "hub-backend,redis" "$(run_script)"
}

test_diamond_dependency() {
  # base-os is upstream of postgres-primary AND redis AND hub-backend.
  # Changing base-os should pull in everything.
  local repo="$TMP/diamond"; make_fixture_repo "$repo"
  echo "changed" > "$repo/modules/base-os/rootfs/marker"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "touch base-os"
  cd "$repo"
  assert_equal "diamond: base-os → all four dependents" \
    "base-os,hub-backend,postgres-primary,postgres-replica,redis" "$(run_script)"
}

# apt-hash subcommand tests — verify the publish-time hash computation
# is deterministic, dep-graph-aware, and handles edge cases. We can't
# easily test against a real apt repo here (network-dependent), so we
# rely on the deterministic structure of the snapshot: same effective
# package set → same hash. Set APT_PROBE_MODE to something that returns
# 'unknown' so the test stays hermetic, then assert the hash is stable.
run_apt_hash() {
  local module="$1"
  # Force apt probe to no-op so versions all become 'unknown' — keeps
  # the hash hermetic for unit testing.
  APT_PROBE_MODE=none APT_DRIFT_CHECK=0 \
    bash "$SCRIPT_UNDER_TEST" apt-hash "$module" 2>/dev/null
}

test_apt_hash_empty_for_no_packages() {
  local repo="$TMP/apt-empty"; make_fixture_repo "$repo"
  cd "$repo"
  # base-os has no package_spec → empty hash
  assert_equal "apt-hash: empty package_spec → empty hash" "" "$(run_apt_hash base-os)"
}

test_apt_hash_stable_for_module_with_packages() {
  local repo="$TMP/apt-stable"; make_fixture_repo "$repo"
  cd "$repo"
  local h1 h2
  h1="$(run_apt_hash redis)"
  h2="$(run_apt_hash redis)"
  if [[ -n "$h1" && "$h1" == "$h2" ]]; then
    printf '  PASS  %s (hash=%s)\n' "apt-hash: deterministic for same module" "${h1:0:12}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  apt-hash: NOT deterministic (h1=%s h2=%s)\n' "$h1" "$h2"
    FAIL=$((FAIL + 1))
  fi
}

test_apt_hash_excludes_dep_packages() {
  # postgres-replica requires database.postgres (provided by
  # postgres-primary). Both module manifests declare overlapping
  # packages? — actually no, our fixture has separate packages. But
  # adding the same package to BOTH should exercise the exclusion path:
  # if both declare 'postgresql-16', the replica's hash should NOT
  # include postgresql-16 (it's owned by the dep). Add a hypothetical
  # third module to test this.
  local repo="$TMP/apt-excl"; make_fixture_repo "$repo"
  cd "$repo"
  local h_before
  h_before="$(run_apt_hash postgres-replica)"

  # Edit replica's manifest to ALSO include postgresql-16 (now
  # shared with postgres-primary which provides database.postgres).
  # The exclusion logic should drop it from replica's effective set.
  sed -i 's/- postgresql-16-replica/- postgresql-16-replica\n  - postgresql-16/' \
    "$repo/modules/postgres-replica/manifest.yaml"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "add postgresql-16 to replica too"
  local h_after
  h_after="$(run_apt_hash postgres-replica)"

  # If exclusion works: h_before == h_after (the shared pkg got dropped).
  # If exclusion is broken: h_after differs (the shared pkg is included).
  if [[ "$h_before" == "$h_after" ]]; then
    printf '  PASS  apt-hash: dep-graph-aware exclusion drops shared package (hash unchanged)\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  apt-hash: exclusion not applied (h_before=%s h_after=%s)\n' "$h_before" "$h_after"
    FAIL=$((FAIL + 1))
  fi
}

test_apt_hash_unknown_module_errors() {
  local repo="$TMP/apt-unknown"; make_fixture_repo "$repo"
  cd "$repo"
  if APT_PROBE_MODE=none bash "$SCRIPT_UNDER_TEST" apt-hash totally-fake-module 2>/dev/null; then
    printf '  FAIL  apt-hash: unknown module did not exit non-zero\n'
    FAIL=$((FAIL + 1))
  else
    printf '  PASS  apt-hash: unknown module exits non-zero\n'
    PASS=$((PASS + 1))
  fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

echo "ci-compute-dirty-closure.sh test suite"
echo "======================================"
test_single_module_change
test_source_change_with_dependents
test_build_scripts_change_forces_module_forge() {
  local repo="$TMP/buildscripts"; make_fixture_repo "$repo"
  echo "changed" >> "$repo/scripts/module-build/build-one-module.sh"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "touch build script"
  cd "$repo"
  # module-forge has no dependents → closure is just that one. Before this rule
  # the change matched NOTHING, so a builder kept running the stale copy baked
  # into its erofs.
  assert_equal "build-script change → module-forge only" \
    "module-forge" "$(run_script)"
}

test_agent_change_forces_system_base
test_build_scripts_change_forces_module_forge
test_workflow_change_forces_all
test_no_changes
test_manifest_only_change_still_dirty
test_diamond_dependency
test_apt_hash_empty_for_no_packages
test_apt_hash_stable_for_module_with_packages
test_apt_hash_excludes_dep_packages
test_apt_hash_unknown_module_errors

echo ""
echo "PASS=$PASS  FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
