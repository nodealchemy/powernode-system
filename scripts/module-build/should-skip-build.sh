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
# shellcheck source=needs-parent-modules.sh
. "$SCRIPT_DIR/needs-parent-modules.sh"

# Modules whose build reads content OUTSIDE modules/<slug>/, so the default
# input path is INCOMPLETE for them and a skip would compare an incomplete hash:
#
#   powernode-hub-worker|hub-frontend              stage15's needs_parent list —
#                                                  their WHOLE payload (worker/,
#                                                  frontend dist) IS a packaged
#                                                  subtree of the parent core
#                                                  repo, fully covered by
#                                                  folding --core-ref into the
#                                                  hash (see below) — no local
#                                                  BUILD_INPUT_PATHS needed, so
#                                                  these two stay OFF this list.
#   powernode-hub-backend                          ALSO packages a subtree of
#                                                  the parent core repo
#                                                  (server/), but
#                                                  IMP-094d900f9093 added a
#                                                  re-lock step that ALSO reads
#                                                  this repo's OWN root content
#                                                  (server/*.gemspec,
#                                                  extension.json — staged via
#                                                  stage-extension-system-
#                                                  files.sh, folded into
#                                                  server/Gemfile.lock) — the
#                                                  same "reads THIS repo's root,
#                                                  not just the parent subtree"
#                                                  shape powernode-extension-
#                                                  system already has below, so
#                                                  it joins this list for the
#                                                  same reason. It is
#                                                  narrow-dispatched, so rather
#                                                  than thread real
#                                                  --input-path declarations
#                                                  through for it, it takes the
#                                                  same "always refuse to skip"
#                                                  shape as powernode-system-base
#                                                  and module-forge below —
#                                                  nothing currently sets
#                                                  BUILD_INPUT_PATHS for any of
#                                                  the three.
#   powernode-extension-system                     ALSO in needs_parent (it
#                                                  clones the parent for its
#                                                  separate dedicated-module
#                                                  frontend build), but unlike
#                                                  the three above, its PRIMARY
#                                                  payload (server/, config/,
#                                                  worker/, extension.json, plus
#                                                  the scripts that stage them:
#                                                  stage15.sh,
#                                                  stage-extension-system-files.sh)
#                                                  is THIS repo's own content,
#                                                  at the repo ROOT — not under
#                                                  modules/powernode-extension-
#                                                  system/ and not part of the
#                                                  parent subtree --core-ref
#                                                  covers. Folding --core-ref in
#                                                  (which it still needs, for
#                                                  the frontend-build half) does
#                                                  NOTHING to make that payload
#                                                  visible to the hash. Belongs
#                                                  on THIS list for that reason
#                                                  — see IMP-fad0b3f67255's
#                                                  follow-up: batch 01a0e546
#                                                  hashed an unchanged
#                                                  modules/powernode-extension-
#                                                  system/ tree + an unchanged
#                                                  core-ref and silently
#                                                  re-tagged v130's
#                                                  config/-less digest as v131,
#                                                  even though the very commit
#                                                  in that range added config/
#                                                  staging.
#   powernode-system-base                          cross-compiles the Go
#                                                  agent, reading agent/
#                                                  (incl. agent/go.mod)
#   module-forge                                   bakes scripts/module-build/*
#                                                  into its own rootfs
#
# ALSO LOAD-BEARING FOR THE CORE PIN (do not lift the hub-backend/-worker/
# -frontend three by simply declaring BUILD_INPUT_PATHS instead): stage15.sh
# now fetches the batch's expected core commit via $CORE_REF, but that ref is
# NOT an input to compute-build-inputs-hash.sh on its own. A batch pinned to a
# NEW core sha with an unchanged module tree would therefore hash identically,
# skip, and re-tag the previously-built OLD-core digest — the stale-core shape
# the pin exists to remove, this time arriving as a promote-gate `mismatch`
# with no obvious cause. Fold CORE_REF into the hash before enabling skips for
# these modules (see core_ref_hash_args in needs-parent-modules.sh).
#
# STAGE15 ARMS (IMP-24d473c6f448). Every module that has its own arm in
# stage15.sh's module dispatch also reads that arm, and the scripts/module-build
# helpers it calls, from OUTSIDE modules/<slug>/. The build planner now targets a
# module for a change confined to that arm, so the skip must not be able to
# answer "inputs unchanged" for it. That is NOT done by listing every arm module
# below (a hand-kept list of slugs that drifts from stage15.sh, and it would stop
# those modules skipping at all): compute-build-inputs-hash.sh folds in the
# module's OWN arm text and the helpers that arm calls, derived from stage15.sh
# itself (stage15-arm.py, parity-tested against the planner's reader) -- the same
# attribution the planner uses, so another module's arm or shared code does not
# invalidate it. That is why powernode-hub-worker/-frontend stay OFF this list:
# the core-ref fold plus the arm fold cover both their inputs. This list keeps
# only the modules whose out-of-tree inputs the hash still cannot see at all.
#
# These REFUSE to skip unless the caller declares their real inputs via
# BUILD_INPUT_PATHS. Encoding it here rather than leaving it to an operator
# allowlist means BUILD_SKIP_UNCHANGED=1 can be turned on globally and still only
# skip modules it is actually safe for — the unsafe ones opt themselves out.
# Keep this list in step with stage15.sh's needs_parent arm.
#
# NEEDS_DECLARED_INPUTS and module_needs_parent() are INDEPENDENT checks, not
# alternatives for the same fact — a module can be (and powernode-extension-
# system now is) on both lists at once. The first checks whether HASH_ARGS
# (from --input-path) is non-empty; the second checks whether CORE_REF_ARG is
# non-empty; core_ref_hash_args() folds --core-ref into the hash purely off
# module_needs_parent(), with no dependency on whether the module is also in
# NEEDS_DECLARED_INPUTS. Listing a needs-parent module here does not disable,
# bypass, or race its core-ref fold — verified by reading the two `if` blocks
# below, not assumed; see test-should-skip-build-declared-inputs.sh's second
# scenario, which declares --input-path for powernode-extension-system and
# confirms it still separately refuses without a --core-ref.
#
# hub-worker/-frontend are NOT listed here: their ONLY out-of-tree input IS
# the parent repo, fully covered by the core-ref fold, so BUILD_INPUT_PATHS
# would add nothing for them. hub-backend and powernode-extension-system are
# BOTH listed: each has an out-of-tree input beyond the parent repo (see
# above) — the core-ref fold does not cover a needs-parent module's OWN
# repo-root content, so they belong here too, same as powernode-system-base
# and module-forge.
NEEDS_DECLARED_INPUTS="powernode-system-base module-forge powernode-extension-system powernode-hub-backend"

note() { echo "[skip-check] $*" >&2; }
build() { note "$1 -> BUILD"; exit 1; }

MODULE=""; REPO="."; REF="HEAD"; APT_SNAPSHOT=""; CORE_REF_ARG="${CORE_REF:-}"
REGISTRY="${APT_REGISTRY:-git.powernode.org}"; OWNER="${APT_OWNER:-powernode}"; TAG="latest"
HASH_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --module)       MODULE="${2:-}"; shift 2 ;;
    --repo)         REPO="${2:-}"; shift 2 ;;
    --ref)          REF="${2:-}"; shift 2 ;;
    --input-path)   HASH_ARGS+=(--input-path "${2:-}"); shift 2 ;;
    --apt-snapshot) APT_SNAPSHOT="${2:-}"; shift 2 ;;
    --core-ref)     CORE_REF_ARG="${2:-}"; shift 2 ;;
    --registry)     REGISTRY="${2:-}"; shift 2 ;;
    --owner)        OWNER="${2:-}"; shift 2 ;;
    --tag)          TAG="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '1,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)              build "unknown argument: $1" ;;
  esac
done

[ -n "$MODULE" ] || build "no --module given"
command -v oras >/dev/null 2>&1 || build "oras not on PATH"

# Self-protection: a module with out-of-tree inputs must have them declared, or
# its hash cannot see a real input and the skip would reuse a stale artifact.
if [ ${#HASH_ARGS[@]} -eq 0 ]; then
  for _m in $NEEDS_DECLARED_INPUTS; do
    [ "$MODULE" = "$_m" ] && build "$MODULE reads inputs outside modules/$MODULE/ and none were declared (set BUILD_INPUT_PATHS)"
  done
fi

# 1. What would this build ship?
# A needs-parent module packages a subtree of the core repo, so its hash is
# only complete with the core commit folded in. Without one we cannot tell a
# same-tree/new-core build from a same-tree/same-core one — exactly the case
# that would re-tag an OLD-core digest — so refuse, matching the fail-safe
# direction of every other error path here.
if module_needs_parent "$MODULE" && [ -z "$CORE_REF_ARG" ]; then
  build "$MODULE packages parent-repo content and no --core-ref/CORE_REF was supplied"
fi

local_args=(--module "$MODULE" --repo "$REPO" --ref "$REF" "${HASH_ARGS[@]+"${HASH_ARGS[@]}"}")
[ -n "$APT_SNAPSHOT" ] && local_args+=(--apt-snapshot "$APT_SNAPSHOT")
# Folded in for needs-parent modules ONLY — core_ref_hash_args returns nothing
# for a package-origin module, whose hash must stay independent of core.
mapfile -t _core_args < <(core_ref_hash_args "$MODULE" "$CORE_REF_ARG")
[ ${#_core_args[@]} -gt 0 ] && local_args+=("${_core_args[@]}")

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
