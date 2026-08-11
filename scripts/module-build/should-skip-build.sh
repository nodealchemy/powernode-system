#!/usr/bin/env bash
# should-skip-build.sh — decide whether ONE module's build can be skipped
# because its inputs are byte-for-byte what the last published artifact was
# built from.
# =============================================================================
# Exit 0  = SKIP  (published artifact's recorded inputs match the local ones)
# Exit 1  = BUILD (they differ, are unknown, or anything at all went wrong)
#
# FAIL-SAFE DIRECTION. Every error path — no annotation, registry unreachable,
# oras missing, hash uncomputable, malformed value — returns BUILD. The two
# failure modes are not symmetric: a wrong BUILD costs one rebuild, a wrong SKIP
# silently ships a stale module to the fleet. There is no cheap way to notice
# the latter, because artifact digests cannot be compared for equality here
# (stage2-carve stamps the build sha into SOURCE_DATE_EPOCH and the erofs UUID,
# so the same files at two shas always produce different bytes — measured
# 187/187 distinct digests on the live registry).
#
# WHY SKIP AT BUILD TIME RATHER THAN NARROW THE PLAN. Reverse-dependency
# expansion rebuilds every transitive dependent of anything dirty — one edit
# under agent/ plans 22 modules. Narrowing that closure was rejected: it would
# break tested parity with ci-compute-dirty-closure.sh and leave CI and
# server-side planning disagreeing about what to build, with under-building
# failing silently. Skipping the WORK preserves planning semantics exactly and
# keeps both planners in agreement; the batch still names the module, it just
# costs nothing to satisfy.
#
# DEFAULT OFF. The caller gates this on BUILD_SKIP_UNCHANGED=1, matching the
# APT_DRIFT_CHECK convention in ci-compute-dirty-closure.sh. Turn it on
# deliberately, after confirming the declared --input-path set is complete for
# the modules you enable it for (see compute-build-inputs-hash.sh's scope note:
# an UNDECLARED input is exactly how a wrong SKIP happens).
#
# Usage:
#   should-skip-build.sh --module <slug> [--repo <dir>] [--ref <rev>]
#                        [--input-path <path>]... [--apt-snapshot <id>]
#                        [--registry <host>] [--owner <ns>] [--tag <tag>]

set -uo pipefail

ANNOTATION_KEY="org.powernode.build-inputs-sha256"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

note() { echo "[skip-check] $*" >&2; }
build() { note "$1 -> BUILD"; exit 1; }

MODULE=""; REPO="."; REF="HEAD"; APT_SNAPSHOT=""
REGISTRY="${APT_REGISTRY:-git.powernode.org}"; OWNER="${APT_OWNER:-powernode}"; TAG="latest"
HASH_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --module)       MODULE="${2:-}"; shift 2 ;;
    --repo)         REPO="${2:-}"; shift 2 ;;
    --ref)          REF="${2:-}"; shift 2 ;;
    --input-path)   HASH_ARGS+=(--input-path "${2:-}"); shift 2 ;;
    --apt-snapshot) APT_SNAPSHOT="${2:-}"; shift 2 ;;
    --registry)     REGISTRY="${2:-}"; shift 2 ;;
    --owner)        OWNER="${2:-}"; shift 2 ;;
    --tag)          TAG="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '1,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)              build "unknown argument: $1" ;;
  esac
done

[ -n "$MODULE" ] || build "no --module given"
command -v oras >/dev/null 2>&1 || build "oras not on PATH"

# 1. What would this build ship?
local_args=(--module "$MODULE" --repo "$REPO" --ref "$REF" "${HASH_ARGS[@]+"${HASH_ARGS[@]}"}")
[ -n "$APT_SNAPSHOT" ] && local_args+=(--apt-snapshot "$APT_SNAPSHOT")

local_hash=$(bash "$SCRIPT_DIR/compute-build-inputs-hash.sh" "${local_args[@]}" 2>/dev/null) \
  || build "could not compute local inputs hash for $MODULE"
[ -n "$local_hash" ] || build "local inputs hash empty for $MODULE"

# 2. What was the last published artifact built from? A first-ever publish has
#    no annotation, which correctly reads as BUILD.
manifest=$(oras manifest fetch "$REGISTRY/$OWNER/$MODULE:$TAG" 2>/dev/null) \
  || build "no published manifest for $MODULE:$TAG (first publish, or registry unreachable)"

published_hash=$(printf '%s' "$manifest" \
  | jq -r --arg k "$ANNOTATION_KEY" '.annotations[$k] // empty' 2>/dev/null)
[ -n "$published_hash" ] || build "$MODULE:$TAG carries no $ANNOTATION_KEY annotation"

# 3. Compare. Only an exact match skips.
if [ "$local_hash" = "$published_hash" ]; then
  note "$MODULE inputs unchanged ($local_hash) -> SKIP"
  exit 0
fi

note "$MODULE inputs changed (local=$local_hash published=$published_hash) -> BUILD"
exit 1
