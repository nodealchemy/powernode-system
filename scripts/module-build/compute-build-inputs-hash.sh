#!/usr/bin/env bash
# compute-build-inputs-hash.sh — deterministic content hash of ONE module's
# build inputs, for the content-addressed build skip.
# =============================================================================
# WHY THIS EXISTS
#
# A module's artifact digest can never be used to tell "did anything actually
# change?", because stage2-carve.sh stamps the BUILD SHA into the image:
#
#     SOURCE_DATE_EPOCH=$(git log -1 --format=%ct "$GITHUB_SHA")
#     EROFS_UUID=$(uuidgen --sha1 --namespace @oid --name "$MODULE@$GITHUB_SHA")
#
# Both are pure functions of the sha, so the same files built at two different
# shas produce different bytes BY CONSTRUCTION. Measured on the live registry:
# 187 distinct oci_digests across 187 digested versions — zero repeats, across
# 23 modules with multiple builds. Digest comparison is therefore useless as a
# change detector, and a content hash of the INPUTS is the only way to know a
# rebuild would ship the same files.
#
# This matters because reverse-dependency expansion rebuilds every transitive
# dependent of anything dirty: one edit under agent/ plans 22 modules (measured
# 2026-08-11). Narrowing that closure was rejected — it would break tested
# parity with ci-compute-dirty-closure.sh and make CI and server-side planning
# disagree. Skipping the WORK for a module whose inputs are unchanged gets the
# saving without touching planning semantics.
#
# WHAT IS HASHED
#
# Git tree/blob object ids, not file bytes: `git rev-parse <ref>:<path>` IS a
# content hash, it is already computed, and it is exact for a whole subtree.
# The hash covers, in a fixed order:
#
#   1. each --input-path's object id at --ref (default: the module's own
#      modules/<slug> tree)
#   2. the --apt-snapshot id, when given — the package closure is an input the
#      git tree cannot see
#
# Deliberately NOT hashed: the build sha, timestamps, the erofs UUID, and the
# output digest — the very things that vary per build without changing content.
#
# SCOPE / HONEST LIMIT
#
# Input paths are DECLARED by the caller, not inferred. For a package-origin
# module the default (modules/<slug>) is complete. A platform module whose
# stage15 arm packages a parent-repo subtree (hub-backend ships server/**,
# scripts/**, extensions_loader_helper.rb) MUST have those passed explicitly
# with --input-path, against a --repo/--ref pointing at the parent checkout.
# Omitting them yields a hash that misses a real input, so the skip would reuse
# a stale artifact. That direction of error is silent, which is why the skip
# that consumes this hash is default-OFF (BUILD_SKIP_UNCHANGED).
#
# Usage:
#   compute-build-inputs-hash.sh --module <slug> [--repo <dir>] [--ref <rev>]
#                                [--input-path <path>]... [--apt-snapshot <id>]
#
# Prints the hex sha256 on stdout. Exit 0 on success, non-zero on error.

set -euo pipefail

die() { echo "[build-inputs-hash] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
compute-build-inputs-hash.sh — deterministic hash of a module's build inputs.

  --module <slug>        REQUIRED. Module slug; also seeds the default input path.
  --repo <dir>           Git checkout to resolve paths in (default: cwd).
  --ref <rev>            Revision to resolve against (default: HEAD).
  --input-path <path>    Repeatable. Path whose content is an input. Defaults to
                         modules/<slug> when none are given.
  --apt-snapshot <id>    Optional apt snapshot id, folded into the hash.
  -h | --help            This text.
USAGE
}

MODULE=""
REPO="."
REF="HEAD"
APT_SNAPSHOT=""
INPUT_PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --module)       [ $# -ge 2 ] || die "--module requires an argument";       MODULE="$2"; shift 2 ;;
    --repo)         [ $# -ge 2 ] || die "--repo requires an argument";         REPO="$2"; shift 2 ;;
    --ref)          [ $# -ge 2 ] || die "--ref requires an argument";          REF="$2"; shift 2 ;;
    --input-path)   [ $# -ge 2 ] || die "--input-path requires an argument";   INPUT_PATHS+=("$2"); shift 2 ;;
    --apt-snapshot) [ $# -ge 2 ] || die "--apt-snapshot requires an argument"; APT_SNAPSHOT="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$MODULE" ] || { usage >&2; die "--module is required"; }
[ -d "$REPO/.git" ] || git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout: $REPO"

# Default to the module's own tree. A package-origin module needs nothing else.
if [ ${#INPUT_PATHS[@]} -eq 0 ]; then
  INPUT_PATHS=("modules/$MODULE")
fi

# Sorted so argument ORDER cannot change the hash — the same inputs given in a
# different order must produce the same result, or the skip misfires on a
# caller's cosmetic change.
mapfile -t SORTED_PATHS < <(printf '%s\n' "${INPUT_PATHS[@]}" | sort -u)

digest_input=""
for path in "${SORTED_PATHS[@]}"; do
  # rev-parse <ref>:<path> is the git object id of that tree or blob — a content
  # hash of the whole subtree, already computed by git.
  if ! oid=$(git -C "$REPO" rev-parse --quiet --verify "$REF:$path" 2>/dev/null); then
    # A declared input that does not exist is an ERROR, not an empty string:
    # silently hashing "" would make a deleted or mistyped path look unchanged
    # and reuse a stale artifact.
    die "input path not found at $REF: $path (declared for module $MODULE)"
  fi
  digest_input+="${path}:${oid}"$'\n'
done

if [ -n "$APT_SNAPSHOT" ]; then
  digest_input+="apt-snapshot:${APT_SNAPSHOT}"$'\n'
fi

printf '%s' "$digest_input" | sha256sum | awk '{print $1}'
