#!/usr/bin/env bash
# module-artifact-diff.sh — structural diff between two Powernode module
# .erofs images.
#
# The parity gate (native vs. Gitea builds, and the determinism
# verification for THIS increment — campaign 019f5885 inc5) needs to know
# whether two erofs artifacts ship the same CONTENT, not just whether
# their bytes match. A byte-for-byte / fsverity-root comparison is the
# strongest signal (see the build workflow's `fsverity digest` step) but
# gives no diagnostic detail when two artifacts differ — e.g. two
# different build pipelines producing functionally-identical rootfs with
# different erofs metadata layout, or a real regression that added/
# removed/changed a file. This script bridges that gap: it extracts both
# images and diffs their file trees structurally.
#
# Method: `fsck.erofs --extract=DIR` (erofs-utils) rather than a loop
# mount — same rationale as the build workflow's mmdebstrap choice
# (--mode=root over buildah): the Gitea Actions container can't grant
# CAP_SYS_ADMIN for a mount, and extraction needs no privilege at all.
#
# For each image, builds a sorted manifest of every path:
#   regular file → sha256 of its content
#   symlink      → its link target (not followed)
#   directory    → structural presence only (content field is "-")
#   other        → flagged as unsupported (module erofs images are not
#                  expected to carry device/fifo/socket nodes — Stage 2's
#                  rsync file_spec never carves /dev — but the script
#                  still records rather than silently ignoring one)
#
# Two images are IDENTICAL iff every path has the same type AND the same
# content signature. File permissions/ownership are intentionally NOT
# part of the identity check (both are normalized to root:root by the
# build's `mkfs.erofs --all-root`; a future increment can add a
# permission-diff mode if umask drift ever needs catching).
#
# Usage:
#   module-artifact-diff.sh IMAGE_A.erofs IMAGE_B.erofs [options]
#
# Options:
#   --json FILE     also write a machine-readable JSON summary to FILE
#                   (use --json /dev/stdout to print JSON instead of the
#                   human report)
#   --keep-tmp      don't delete the extraction temp dirs (debugging);
#                   the script prints their paths before exiting
#   -q, --quiet     suppress the human-readable report (JSON / exit code
#                   only)
#   -h, --help      show this help and exit
#
# Exit codes:
#   0  images are structurally identical
#   1  images differ (report on stdout, or in --json)
#   2  usage error or extraction/tooling failure
#
# Requires: fsck.erofs (erofs-utils), sha256sum, find (GNU, for
# `-printf`), sort. jq is only required when --json is given.

set -euo pipefail

usage() {
  # Print the header comment block above (everything between the first
  # and second '#!' — simplest to just re-state it tersely here) so
  # `--help` doesn't drift from the file header.
  cat <<'EOF'
Usage: module-artifact-diff.sh IMAGE_A.erofs IMAGE_B.erofs [options]

Structurally diffs two Powernode module erofs images: extracts each via
`fsck.erofs --extract`, builds a sorted "path<TAB>type<TAB>content"
manifest per image (content = sha256 for regular files, symlink target
for symlinks, "-" for directories), and reports added / removed /
changed paths.

Options:
  --json FILE     also write a machine-readable JSON summary to FILE
                  (--json /dev/stdout prints JSON instead of the human
                  report)
  --keep-tmp      don't delete the extraction temp dirs (debugging)
  -q, --quiet     suppress the human-readable report; JSON/exit code only
  -h, --help      show this help and exit

Exit codes:
  0  images are structurally identical
  1  images differ
  2  usage error or extraction/tooling failure
EOF
}

die() {
  echo "module-artifact-diff.sh: error: $*" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

IMAGE_A=""
IMAGE_B=""
JSON_OUT=""
KEEP_TMP=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      [ $# -ge 2 ] || die "--json requires an argument"
      JSON_OUT="$2"
      shift 2
      ;;
    --keep-tmp)
      KEEP_TMP=1
      shift
      ;;
    -q|--quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ -z "$IMAGE_A" ]; then
        IMAGE_A="$1"
      elif [ -z "$IMAGE_B" ]; then
        IMAGE_B="$1"
      else
        die "unexpected extra argument: $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$IMAGE_A" ] || [ -z "$IMAGE_B" ]; then
  usage >&2
  die "two image paths are required"
fi
[ -f "$IMAGE_A" ] || die "not a file: $IMAGE_A"
[ -f "$IMAGE_B" ] || die "not a file: $IMAGE_B"

require_cmd fsck.erofs
require_cmd sha256sum
require_cmd find
require_cmd sort
if [ -n "$JSON_OUT" ]; then
  require_cmd jq
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/module-artifact-diff.XXXXXX")"

# shellcheck disable=SC2317  # invoked indirectly via `trap ... EXIT` below
cleanup() {
  if [ "$KEEP_TMP" -eq 1 ]; then
    echo "module-artifact-diff.sh: kept extraction dirs under $TMP_ROOT" >&2
  else
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

EXTRACT_A="$TMP_ROOT/a"
EXTRACT_B="$TMP_ROOT/b"
mkdir -p "$EXTRACT_A" "$EXTRACT_B"

# Extract an erofs image into a directory. fsck.erofs also validates
# filesystem integrity as a side effect (its primary purpose) — a
# corrupt image fails here with a non-zero exit before we ever get to
# the structural comparison.
extract_image() {
  image="$1"
  dest="$2"
  log="$TMP_ROOT/$(basename "$dest").extract.log"
  if ! fsck.erofs --extract="$dest" "$image" >"$log" 2>&1; then
    echo "module-artifact-diff.sh: fsck.erofs --extract failed for $image" >&2
    cat "$log" >&2
    exit 2
  fi
}

extract_image "$IMAGE_A" "$EXTRACT_A"
extract_image "$IMAGE_B" "$EXTRACT_B"

# Build a sorted "path<TAB>type<TAB>content" manifest for one extracted
# tree. NUL-delimited `find` records keep this correct even for the
# (unexpected, but not fatal) case of a path containing a literal tab or
# newline — the type char from `%y` is always exactly one byte, so
# splitting on the first two characters of each record is unambiguous
# regardless of what the path itself contains.
build_manifest() {
  root="$1"
  outfile="$2"
  : > "$outfile"
  while IFS= read -r -d '' rec; do
    ftype="${rec:0:1}"
    rel="${rec:2}"
    case "$ftype" in
      f)
        content="$(sha256sum -- "$root/$rel" | cut -d' ' -f1)"
        ;;
      l)
        content="$(readlink -- "$root/$rel")"
        ;;
      d)
        content="-"
        ;;
      *)
        content="unsupported-type:$ftype"
        ;;
    esac
    printf '%s\t%s\t%s\n' "$rel" "$ftype" "$content"
  done < <(find "$root" -mindepth 1 -printf '%y\t%P\0') | LC_ALL=C sort -t "$(printf '\t')" -k1,1 > "$outfile"
}

MANIFEST_A="$TMP_ROOT/manifest_a.tsv"
MANIFEST_B="$TMP_ROOT/manifest_b.tsv"
build_manifest "$EXTRACT_A" "$MANIFEST_A"
build_manifest "$EXTRACT_B" "$MANIFEST_B"

declare -A A_ENTRY=()
declare -A B_ENTRY=()

while IFS=$'\t' read -r path ftype content; do
  A_ENTRY["$path"]="$ftype	$content"
done < "$MANIFEST_A"

while IFS=$'\t' read -r path ftype content; do
  B_ENTRY["$path"]="$ftype	$content"
done < "$MANIFEST_B"

ADDED_LIST="$TMP_ROOT/added.txt"
REMOVED_LIST="$TMP_ROOT/removed.txt"
CHANGED_LIST="$TMP_ROOT/changed.txt"
: > "$ADDED_LIST"
: > "$REMOVED_LIST"
: > "$CHANGED_LIST"

for path in "${!B_ENTRY[@]}"; do
  if [ -z "${A_ENTRY[$path]+x}" ]; then
    printf '%s\n' "$path" >> "$ADDED_LIST"
  fi
done

for path in "${!A_ENTRY[@]}"; do
  if [ -z "${B_ENTRY[$path]+x}" ]; then
    printf '%s\n' "$path" >> "$REMOVED_LIST"
  elif [ "${A_ENTRY[$path]}" != "${B_ENTRY[$path]}" ]; then
    printf '%s\n' "$path" >> "$CHANGED_LIST"
  fi
done

LC_ALL=C sort -o "$ADDED_LIST" "$ADDED_LIST"
LC_ALL=C sort -o "$REMOVED_LIST" "$REMOVED_LIST"
LC_ALL=C sort -o "$CHANGED_LIST" "$CHANGED_LIST"

ADDED_COUNT="$(wc -l < "$ADDED_LIST" | tr -d ' ')"
REMOVED_COUNT="$(wc -l < "$REMOVED_LIST" | tr -d ' ')"
CHANGED_COUNT="$(wc -l < "$CHANGED_LIST" | tr -d ' ')"
TOTAL_A="$(wc -l < "$MANIFEST_A" | tr -d ' ')"
TOTAL_B="$(wc -l < "$MANIFEST_B" | tr -d ' ')"

if [ "$ADDED_COUNT" -eq 0 ] && [ "$REMOVED_COUNT" -eq 0 ] && [ "$CHANGED_COUNT" -eq 0 ]; then
  IDENTICAL=1
else
  IDENTICAL=0
fi

if [ "$QUIET" -eq 0 ]; then
  echo "=== module-artifact-diff: $IMAGE_A vs $IMAGE_B ==="
  echo "entries: a=$TOTAL_A b=$TOTAL_B"
  if [ "$IDENTICAL" -eq 1 ]; then
    echo "IDENTICAL — no structural differences"
  else
    echo "DIFFERENT — added=$ADDED_COUNT removed=$REMOVED_COUNT changed=$CHANGED_COUNT"
    if [ "$ADDED_COUNT" -gt 0 ]; then
      echo "--- added in B (not in A) ---"
      sed 's/^/+ /' "$ADDED_LIST"
    fi
    if [ "$REMOVED_COUNT" -gt 0 ]; then
      echo "--- removed in B (present in A) ---"
      sed 's/^/- /' "$REMOVED_LIST"
    fi
    if [ "$CHANGED_COUNT" -gt 0 ]; then
      echo "--- changed (same path, different type/content) ---"
      while IFS= read -r path; do
        printf '~ %s\n' "$path"
        printf '    a: %s\n' "${A_ENTRY[$path]}" | tr '\t' ' '
        printf '    b: %s\n' "${B_ENTRY[$path]}" | tr '\t' ' '
      done < "$CHANGED_LIST"
    fi
  fi
fi

if [ -n "$JSON_OUT" ]; then
  jq -n \
    --arg image_a "$IMAGE_A" \
    --arg image_b "$IMAGE_B" \
    --argjson identical "$([ "$IDENTICAL" -eq 1 ] && echo true || echo false)" \
    --argjson total_a "$TOTAL_A" \
    --argjson total_b "$TOTAL_B" \
    --slurpfile added <(jq -R -s 'split("\n") | map(select(length > 0))' "$ADDED_LIST") \
    --slurpfile removed <(jq -R -s 'split("\n") | map(select(length > 0))' "$REMOVED_LIST") \
    --slurpfile changed <(jq -R -s 'split("\n") | map(select(length > 0))' "$CHANGED_LIST") \
    '{
       image_a: $image_a,
       image_b: $image_b,
       identical: $identical,
       summary: {
         total_a: $total_a,
         total_b: $total_b,
         added: ($added[0] | length),
         removed: ($removed[0] | length),
         changed: ($changed[0] | length)
       },
       added: $added[0],
       removed: $removed[0],
       changed: $changed[0]
     }' > "$JSON_OUT"
fi

if [ "$IDENTICAL" -eq 1 ]; then
  exit 0
else
  exit 1
fi
