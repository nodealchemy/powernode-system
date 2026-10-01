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
#   2. the module's OWN stage15.sh arm text and the scripts/module-build helpers
#      that arm calls, for a module with an arm in stage15.sh's module dispatch
#      -- see BUILD SCRIPTS below; plus, for a module needs-parent-modules.sh
#      lists, stage15.sh's shared parent-clone block (IMP-c19b10a942d7), the
#      text between its `# --- BEGIN/END needs-parent shared block ---` markers,
#      which sits outside every arm but builds /tmp/parent and
#      /tmp/parent-build-info.json for exactly those modules
#   3. the --apt-snapshot id, when given — the package closure is an input the
#      git tree cannot see
#   4. the --core-ref commit, when given — the parent-repo subtree a needs-parent
#      module packages is an input NO path in this repo can see
#
# BUILD SCRIPTS (IMP-24d473c6f448). A module's stage15.sh arm, and the helpers
# that arm calls, decide what its artifact contains but live in
# scripts/module-build/, outside modules/<slug>/ -- so a change confined to one
# arm left the tree hash untouched and the skip re-tagged the old digest. The
# build planner now targets a module for exactly that kind of change
# (System::ModuleBuildScriptAttribution), which would have made the skip the
# thing that defeats it. So a module with its OWN arm folds in the sha256 of that
# arm's text and the blob id of each scripts/module-build helper the arm calls
# (stage15-arm.py, a port of the planner's reader, parity-tested against it).
#
# Deliberately NOT the whole scripts tree: ~16 script commits a month would then
# invalidate every arm module, rebuilding (and auto-promoting) modules whose own
# arm nothing touched. Another module's arm, shared code outside every arm, and a
# script no arm calls therefore leave this module's hash alone -- the same
# attribution the planner uses. A module with NO arm (package-origin) hashes
# exactly as before, so it keeps skipping.
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
#                                [--core-ref <sha>]
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
  --core-ref <sha>       Optional parent (core) commit, folded into the hash.
                         Pass it ONLY for a module whose build packages a
                         parent-repo subtree — see needs-parent-modules.sh.
  -h | --help            This text.
USAGE
}

MODULE=""
REPO="."
REF="HEAD"
APT_SNAPSHOT=""
CORE_REF_ARG=""
INPUT_PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --module)       [ $# -ge 2 ] || die "--module requires an argument";       MODULE="$2"; shift 2 ;;
    --repo)         [ $# -ge 2 ] || die "--repo requires an argument";         REPO="$2"; shift 2 ;;
    --ref)          [ $# -ge 2 ] || die "--ref requires an argument";          REF="$2"; shift 2 ;;
    --input-path)   [ $# -ge 2 ] || die "--input-path requires an argument";   INPUT_PATHS+=("$2"); shift 2 ;;
    --apt-snapshot) [ $# -ge 2 ] || die "--apt-snapshot requires an argument"; APT_SNAPSHOT="$2"; shift 2 ;;
    --core-ref)     [ $# -ge 2 ] || die "--core-ref requires an argument";     CORE_REF_ARG="$2"; shift 2 ;;
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

# The module's own stage15.sh arm + the helpers it calls, read at the SAME ref
# the rest of the hash is taken at. stage15-arm.py exits 1 for a module with no
# arm (nothing to fold) and 2 for a script it cannot read faithfully; the latter
# FAILS the hash -- should-skip then reads BUILD and push.sh omits the annotation,
# never a hash silently missing the arm.
STAGE15_REL="scripts/module-build/stage15.sh"
if git -C "$REPO" cat-file -e "$REF:$STAGE15_REL" 2>/dev/null; then
  command -v python3 >/dev/null 2>&1 || die "python3 not found; needed to read the stage15.sh arm for $MODULE"
  ARM_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stage15-arm.py"
  [ -f "$ARM_PY" ] || die "stage15-arm.py missing next to $0"
  # needs-parent-modules.sh is the LIST stage15-arm.py takes beside the script
  # (below), never a helper: its content reaches the hash only through which
  # modules the block is folded into, the same line the planner's reader draws
  # (System::ModuleBuildScriptAttribution never treats it as a helper either).
  NEEDS_PARENT_REL="scripts/module-build/needs-parent-modules.sh"
  mapfile -t helper_names < <(git -C "$REPO" ls-tree --name-only "$REF" scripts/module-build/ 2>/dev/null \
    | while IFS= read -r f; do b="${f##*/}"; case "$b" in stage15.sh|"${NEEDS_PARENT_REL##*/}") ;; *) printf '%s\n' "$b" ;; esac; done)
  # needs-parent-modules.sh at the SAME ref (IMP-c19b10a942d7): the slugs that
  # own stage15.sh's shared parent-clone block, so the block is folded into
  # exactly their hashes. Absent at the ref means no list (a fixture repo).
  # Present but without its list -- which is every ref older than the list,
  # where the file still has its case-statement shape -- or a block nobody
  # owns, makes stage15-arm.py exit 2 and this hash FAIL, never a hash that
  # silently misses the block. A build runs the scripts checked out at the ref
  # it builds, so this reader only meets an older ref through a baked-scripts
  # fallback, where FAIL (the skip then reads BUILD) is the safe answer.
  arm_tmp="$(mktemp -d)" || die "mktemp failed"
  trap 'rm -rf "$arm_tmp"' EXIT
  arm_args=()
  if git -C "$REPO" cat-file -e "$REF:$NEEDS_PARENT_REL" 2>/dev/null; then
    git -C "$REPO" show "$REF:$NEEDS_PARENT_REL" > "$arm_tmp/needs-parent-modules.sh" \
      || die "could not read $NEEDS_PARENT_REL at $REF"
    arm_args=(--needs-parent-modules "$arm_tmp/needs-parent-modules.sh")
  fi
  arm_rc=0
  arm_out=$(git -C "$REPO" show "$REF:$STAGE15_REL" 2>/dev/null \
    | python3 "$ARM_PY" "${arm_args[@]+"${arm_args[@]}"}" "$MODULE" "${helper_names[@]+"${helper_names[@]}"}" 2>"$arm_tmp/arm.err") || arm_rc=$?
  case "$arm_rc" in
    0)
      while IFS=' ' read -r kind value; do
        case "$kind" in
          arm-sha256) digest_input+="stage15-arm:${value}"$'\n' ;;
          helper)
            h_oid=$(git -C "$REPO" rev-parse --quiet --verify "$REF:scripts/module-build/$value" 2>/dev/null) \
              || die "helper scripts/module-build/$value not found at $REF"
            digest_input+="build-helper:${value}:${h_oid}"$'\n' ;;
        esac
      done <<<"$arm_out"
      ;;
    1) : ;; # no arm of its own
    *) die "could not read stage15.sh's arm for $MODULE at $REF (unparseable dispatch: $(tr '\n' ' ' <"$arm_tmp/arm.err"))" ;;
  esac
fi

if [ -n "$APT_SNAPSHOT" ]; then
  digest_input+="apt-snapshot:${APT_SNAPSHOT}"$'\n'
fi

# The parent (core) commit this build packages a subtree of. Folded in ONLY
# when the caller passes it, which needs-parent-modules.sh does for exactly the
# four modules whose stage15 arm clones the core repo. Passing it for a
# package-origin module would be a regression: its hash would then change on
# every core commit and it could never skip.
#
# This closes the gap should-skip-build.sh documented and refused to skip
# around: stage15 fetches the batch's expected core commit via $CORE_REF, but
# that ref was NOT an input here, so a batch pinned to a NEW core sha with an
# unchanged module tree hashed identically, skipped, and re-tagged the
# previously-built OLD-core digest — arriving later as an unexplained promote
# gate `mismatch`.
if [ -n "$CORE_REF_ARG" ]; then
  digest_input+="core-ref:${CORE_REF_ARG}"$'\n'
fi

printf '%s' "$digest_input" | sha256sum | awk '{print $1}'
