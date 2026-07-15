#!/usr/bin/env bash
# derive-file-spec.sh — package-ownership file_spec derivation + carve
# conformance check for the manifest-driven module-build pipeline
# (stage1-rootfs.sh / stage2-carve.sh / build-one-module.sh).
#
# Two subcommands:
#
#   derive       Computes a module's OWNED file set: the packages the
#                module's package_spec pulls in that base-os-ubuntu-noble
#                does NOT already provide (set difference of the two
#                Stage-1 packages.txt captures, by package name), expanded
#                to their file lists via `dpkg-query -L` against the fat
#                rootfs's dpkg admindir. This is the same "dpkg -L
#                ownership" technique PackageBuildWebhookService /
#                build-package-module.yaml already use to derive file_spec
#                for auto-generated package modules (see that workflow's
#                "Carve per-module tarballs" step) — applied here as a
#                *measurement*, not a write path, against manifest-driven
#                modules that declare file_spec by hand.
#
#   conformance  Expands the module's manifest file_spec + mask (+
#                protected_spec) against the fat tree using the IDENTICAL
#                rsync filter semantics stage2-carve.sh's Stage 2 carve
#                uses (mask as "- <glob>", file_spec + protected_spec as
#                "+ <glob>", trailing "- *", "+ */" evaluated first,
#                --prune-empty-dirs) to get the CARVED set, then diffs it
#                against the OWNED set from `derive`:
#                  - carved-but-not-owned, excluding this module's own
#                    rootfs/ overlay content (which is legitimately
#                    module-owned via hand-authored files, not apt
#                    ownership — see stage2-carve.sh's rootfs/ layering) ->
#                    FAIL (over-inclusion)
#                  - owned-but-not-carved -> WARN (under-carve), unless
#                    waived per-path via the manifest's `carve_waivers:`
#                    key (a list of globs, case-pattern matched against
#                    the absolute path — see modules/.schema and
#                    docs/MODULE_MANIFEST_COMPLETE_SCHEMA.md)
#
# base-os-ubuntu-noble is exempt from the FAIL: it legitimately owns the
# base userland (its file_spec breadth is the documented exception — see
# modules/base-os-ubuntu-noble/manifest.yaml), so its over-inclusion is
# reported as an informational WARN, never a FAIL.
#
# Naming note: --workspace here means the SAME thing it means in
# stage2-carve.sh / build-one-module.sh (the checked-out repo root, used
# to read modules/$MODULE/manifest.yaml and modules/$MODULE/rootfs/). The
# fat rootfs directory (what those scripts hardcode as /tmp/fat) is a
# DIFFERENT directory and is threaded through explicitly as --fat-root so
# this script — unlike the stage scripts — can run against a small fixture
# tree in tests without a full mmdebstrap build.
#
# Usage:
#   derive-file-spec.sh derive --module MODULE --fat-root DIR
#                        [--packages-dir DIR] [--base-module SLUG]
#
#   derive-file-spec.sh conformance --module MODULE --workspace DIR
#                        --fat-root DIR [--packages-dir DIR]
#                        [--base-module SLUG]
#
# derive:
#   --module MODULE       module slug (matches a $MODULE.packages.txt in
#                          --packages-dir, as written by stage1-rootfs.sh)
#   --fat-root DIR         the built fat rootfs directory (dpkg admindir is
#                          DIR/var/lib/dpkg) — /tmp/fat in the real
#                          pipeline, a fixture tree in tests
#   --packages-dir DIR     dir holding $MODULE.packages.txt files (default:
#                          /tmp, matching stage1-rootfs.sh's hardcoded
#                          output path)
#   --base-module SLUG     the baseline module subtracted out (default:
#                          base-os-ubuntu-noble); when --module equals
#                          --base-module, the "owned" set is ALL of its own
#                          resolved packages (no baseline to subtract —
#                          base-os owns its own userland by definition)
#   Prints the owned-file list (one absolute path per line, LC_ALL=C
#   sorted) to stdout.
#
# conformance:
#   --module MODULE
#   --workspace DIR        checked-out repo root — see the naming note
#                          above
#   --fat-root DIR         see derive
#   --packages-dir DIR     see derive
#   --base-module SLUG     see derive
#   Prints a report to stdout; exits non-zero only on FAIL (unwaived
#   over-inclusion on a non-base-module). WARN-only or clean results exit
#   0 — this is a non-blocking CHECK for under-carve, a blocking one for
#   over-inclusion, per the design brief.
#
# Design note: every set operation below is factored into a small function
# operating on plain newline-delimited file lists (no global state beyond
# its own arguments) so tests/module-build/test-derive-file-spec.sh can
# `source` this file and drive them directly against fixtures — no
# mmdebstrap/dpkg build required. This file can also be run directly as a
# CLI (see the `main` dispatch at the bottom, gated on direct execution).
#
# Exit: non-zero on FAIL or usage error (set -euo pipefail propagates any
# unexpected subcommand failure too).

set -euo pipefail

die() {
  echo "derive-file-spec.sh: error: $*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
Usage:
  derive-file-spec.sh derive --module MODULE --fat-root DIR
                       [--packages-dir DIR] [--base-module SLUG]

  derive-file-spec.sh conformance --module MODULE --workspace DIR
                       --fat-root DIR [--packages-dir DIR]
                       [--base-module SLUG]

See the file header for the full option reference and semantics.
EOF
}

# =============================================================================
# Pure functions — operate only on their arguments + plain files; safe to
# unit-test directly (see tests/module-build/test-derive-file-spec.sh).
# =============================================================================

# owned_package_names PKG_FILE BASE_FILE
# Package names present in PKG_FILE (stage1-rootfs.sh's dpkg-query -W
# format: Package\tVersion\tArchitecture) that are NOT present (by name)
# in BASE_FILE. LC_ALL=C sorted, one package name per line on stdout.
owned_package_names() {
  local pkg_file="$1" base_file="$2"
  local pkg_names base_names
  pkg_names=$(mktemp)
  base_names=$(mktemp)
  cut -f1 "$pkg_file"  | LC_ALL=C sort -u > "$pkg_names"
  cut -f1 "$base_file" | LC_ALL=C sort -u > "$base_names"
  comm -23 "$pkg_names" "$base_names"
  rm -f "$pkg_names" "$base_names"
}

# owned_files_for_packages FAT_ROOT PACKAGE_NAMES_FILE
# For each package name (one per line, may be empty) in
# PACKAGE_NAMES_FILE, resolves its dpkg -L file list against FAT_ROOT's
# dpkg admindir, keeping only entries that are actually a regular file or
# symlink under FAT_ROOT — this drops the directory entries dpkg -L also
# lists (including the "/." root entry) and drops diversion remnants that
# don't resolve to a real path in this tree. Union, LC_ALL=C sorted,
# de-duplicated, printed to stdout.
owned_files_for_packages() {
  local fat_root="$1" pkg_list="$2"
  local admindir="$fat_root/var/lib/dpkg"
  [ -d "$admindir" ] || die "no dpkg admindir at $admindir"
  local pkg path
  {
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      dpkg-query --admindir="$admindir" -L "$pkg" 2>/dev/null || true
    done < "$pkg_list"
  } | {
    while IFS= read -r path; do
      [ "$path" = "/." ] && continue
      if [ -L "$fat_root$path" ] || [ -f "$fat_root$path" ]; then
        echo "$path"
      fi
    done
  } | LC_ALL=C sort -u
}

# manifest_to_json MANIFEST_YAML OUT_JSON
# Same yq-preferred/python3-fallback technique build-one-module.sh's
# "Parse manifest replication" section uses.
manifest_to_json() {
  local mfpath="$1" out_json="$2"
  if command -v yq >/dev/null 2>&1; then
    yq -o=json '.' "$mfpath" > "$out_json"
  else
    command -v python3 >/dev/null 2>&1 || die "neither yq nor python3 available to parse $mfpath"
    python3 -c "import yaml,json,sys; json.dump(yaml.safe_load(open('$mfpath')), sys.stdout)" > "$out_json"
  fi
}

# build_rsync_carve_filter MASK_FILE FILE_SPEC_FILE PROTECTED_SPEC_FILE OUT_FILE
# Writes the IDENTICAL rsync filter build-one-module.sh's / the workflow's
# "Parse manifest" step builds: mask entries as "- <glob>", then file_spec
# + protected_spec entries as "+ <glob>", then a final "- *". Each *_FILE
# is a plain newline list of globs (may be empty).
build_rsync_carve_filter() {
  local mask_file="$1" file_spec_file="$2" protected_spec_file="$3" out_file="$4"
  {
    awk '{print "- " $0}' "$mask_file"
    awk '{print "+ " $0}' "$file_spec_file"
    awk '{print "+ " $0}' "$protected_spec_file"
    echo "- *"
  } > "$out_file"
}

# carved_files FAT_ROOT FILTER_FILE
# Expands FILTER_FILE (as built by build_rsync_carve_filter) against
# FAT_ROOT using the SAME rsync invocation shape stage2-carve.sh's Stage 2
# carve uses ("+ */" first so directories are kept during traversal, then
# the filter file — first-match-wins — then --prune-empty-dirs) but in
# --dry-run (-n) against a destination that is never created, so nothing
# is written to disk. rsync's --out-format='%n' dry-run listing IS the
# carved set; directory entries report with a trailing "/" (confirmed:
# see this increment's report), which we drop since we only want file
# entries, then prepend "/" to match dpkg -L's absolute-path convention.
carved_files() {
  local fat_root="$1" filter_file="$2"
  local dest
  dest=$(mktemp -u)
  rsync -a -n --out-format='%n' \
    --filter='+ */' \
    --filter=". $filter_file" \
    --prune-empty-dirs \
    "$fat_root/" "$dest/" \
  | { grep -v '/$' || true; } \
  | sed 's#^#/#' \
  | LC_ALL=C sort -u
}

# rootfs_files WORKSPACE MODULE
# Absolute paths (leading "/") of every file/symlink under
# modules/$MODULE/rootfs/ (relative to WORKSPACE) — the module's
# hand-authored overlay content, layered onto the fat tree by
# stage2-carve.sh BEFORE the carve and again onto the slim tree AFTER.
# These are legitimately module-owned even though no dpkg package
# installed them, so conformance excludes them from the over-inclusion
# FAIL. Empty output (not an error) when the module has no rootfs/ dir.
rootfs_files() {
  local workspace="$1" module="$2"
  local dir="$workspace/modules/$module/rootfs"
  if [ -d "$dir" ]; then
    ( cd "$dir" && find . \( -type f -o -type l \) ) | sed 's#^\.##' | LC_ALL=C sort -u
  fi
}

# diff_report OWNED_FILE CARVED_FILE OUT_RAW_OVER OUT_UNDER
# Both inputs must already be LC_ALL=C sorted, newline-delimited absolute
# paths. Writes carved-but-not-owned (raw over-inclusion candidates,
# BEFORE the rootfs/ exclusion) to OUT_RAW_OVER, and owned-but-not-carved
# (under-carve candidates) to OUT_UNDER.
diff_report() {
  local owned="$1" carved="$2" out_raw_over="$3" out_under="$4"
  comm -13 "$owned" "$carved" > "$out_raw_over"  # in carved, not owned
  comm -23 "$owned" "$carved" > "$out_under"     # in owned, not carved
}

# exclude_rootfs_owned RAW_OVER_FILE ROOTFS_FILES_FILE OUT_FILE
# Drops entries present in ROOTFS_FILES_FILE from RAW_OVER_FILE — see
# rootfs_files' header comment for why. Both inputs must be LC_ALL=C
# sorted.
exclude_rootfs_owned() {
  local raw_over="$1" rootfs="$2" out_file="$3"
  comm -23 "$raw_over" "$rootfs" > "$out_file"
}

# apply_carve_waivers UNDER_FILE WAIVERS_FILE OUT_FILE
# Filters UNDER_FILE (owned-but-not-carved paths) by the manifest's
# carve_waivers: globs. Matched via bash `case` pattern matching — a "**"
# behaves the same as a single "*" here since case patterns aren't
# slash-aware to begin with (a case "*" already matches "/"), which is
# consistent with rsync's "match across path segments" intent for "**".
# Every non-waived line is written to OUT_FILE, LC_ALL=C sorted.
apply_carve_waivers() {
  local under_file="$1" waivers_file="$2" out_file="$3"
  : > "$out_file"
  local path glob waived
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    waived=0
    if [ -s "$waivers_file" ]; then
      while IFS= read -r glob; do
        [ -n "$glob" ] || continue
        # shellcheck disable=SC2254  # intentionally unquoted: $glob must
        # be interpreted as a case pattern, not a literal string.
        case "$path" in
          $glob) waived=1; break ;;
        esac
      done < "$waivers_file"
    fi
    [ "$waived" -eq 1 ] || echo "$path" >> "$out_file"
  done < "$under_file"
  LC_ALL=C sort -u -o "$out_file" "$out_file"
}

# =============================================================================
# Subcommands
# =============================================================================

# resolve_owned_packages MODULE BASE_MODULE PACKAGES_DIR OUT_FILE
# Shared by both subcommands: writes the owned package-name list (see
# owned_package_names) to OUT_FILE, handling the base-module special case
# (module == base_module -> owns 100% of its own resolved packages, no
# baseline to subtract).
resolve_owned_packages() {
  local module="$1" base_module="$2" packages_dir="$3" out_file="$4"
  local pkg_file="$packages_dir/$module.packages.txt"
  [ -f "$pkg_file" ] || die "no packages file at $pkg_file (run stage1-rootfs.sh --module $module first)"
  if [ "$module" = "$base_module" ]; then
    cut -f1 "$pkg_file" | LC_ALL=C sort -u > "$out_file"
  else
    local base_file="$packages_dir/$base_module.packages.txt"
    [ -f "$base_file" ] || die "no baseline packages file at $base_file (run stage1-rootfs.sh --module $base_module first)"
    owned_package_names "$pkg_file" "$base_file" > "$out_file"
  fi
}

cmd_derive() {
  local module="" fat_root="" packages_dir="/tmp" base_module="base-os-ubuntu-noble"
  while [ $# -gt 0 ]; do
    case "$1" in
      --module)       [ $# -ge 2 ] || die "--module requires an argument";       module="$2"; shift 2 ;;
      --fat-root)     [ $# -ge 2 ] || die "--fat-root requires an argument";     fat_root="$2"; shift 2 ;;
      --packages-dir) [ $# -ge 2 ] || die "--packages-dir requires an argument"; packages_dir="$2"; shift 2 ;;
      --base-module)  [ $# -ge 2 ] || die "--base-module requires an argument";  base_module="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$module" ]   || die "--module is required"
  [ -n "$fat_root" ] || die "--fat-root is required"
  [ -d "$fat_root" ] || die "--fat-root '$fat_root' is not a directory"

  # No `trap ... EXIT` here on purpose: a trap string referencing a
  # function-`local` variable is expanded when the trap FIRES, which for
  # an EXIT trap is after this function (and its local scope) has already
  # returned — that reliably hits `set -u` as an "unbound variable" error.
  # Explicit cleanup at every return point instead (matches this script
  # family's existing style — stage1-rootfs.sh/stage2-carve.sh don't use
  # traps either).
  local work
  work=$(mktemp -d)

  resolve_owned_packages "$module" "$base_module" "$packages_dir" "$work/owned_pkgs.txt"
  owned_files_for_packages "$fat_root" "$work/owned_pkgs.txt"
  rm -rf "$work"
}

cmd_conformance() {
  local module="" workspace="" fat_root="" packages_dir="/tmp" base_module="base-os-ubuntu-noble"
  while [ $# -gt 0 ]; do
    case "$1" in
      --module)       [ $# -ge 2 ] || die "--module requires an argument";       module="$2"; shift 2 ;;
      --workspace)    [ $# -ge 2 ] || die "--workspace requires an argument";    workspace="$2"; shift 2 ;;
      --fat-root)     [ $# -ge 2 ] || die "--fat-root requires an argument";     fat_root="$2"; shift 2 ;;
      --packages-dir) [ $# -ge 2 ] || die "--packages-dir requires an argument"; packages_dir="$2"; shift 2 ;;
      --base-module)  [ $# -ge 2 ] || die "--base-module requires an argument";  base_module="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$module" ]    || die "--module is required"
  [ -n "$workspace" ] || die "--workspace is required"
  [ -n "$fat_root" ]  || die "--fat-root is required"
  [ -d "$fat_root" ]  || die "--fat-root '$fat_root' is not a directory"

  local mfpath="$workspace/modules/$module/manifest.yaml"
  [ -f "$mfpath" ] || die "no manifest at $mfpath"

  # See cmd_derive's comment: no EXIT trap here — explicit cleanup at the
  # single return point below instead.
  local work
  work=$(mktemp -d)

  # --- carved set (manifest file_spec + mask + protected_spec, expanded
  #     against the fat tree with stage2-carve.sh's exact filter shape) ---
  manifest_to_json "$mfpath" "$work/manifest.json"
  jq -r '.mask[]?'           "$work/manifest.json" > "$work/mask.txt"
  jq -r '.file_spec[]?'      "$work/manifest.json" > "$work/file_spec.txt"
  jq -r '.protected_spec[]?' "$work/manifest.json" > "$work/protected_spec.txt"
  jq -r '.carve_waivers[]?'  "$work/manifest.json" > "$work/carve_waivers.txt"

  build_rsync_carve_filter "$work/mask.txt" "$work/file_spec.txt" "$work/protected_spec.txt" "$work/filter.txt"
  carved_files "$fat_root" "$work/filter.txt" > "$work/carved.txt"

  # --- owned set (package-derived, via derive's own logic) ---
  resolve_owned_packages "$module" "$base_module" "$packages_dir" "$work/owned_pkgs.txt"
  owned_files_for_packages "$fat_root" "$work/owned_pkgs.txt" > "$work/owned.txt"

  # --- diff + rootfs/ exclusion + waivers ---
  diff_report "$work/owned.txt" "$work/carved.txt" "$work/raw_over.txt" "$work/under.txt"
  rootfs_files "$workspace" "$module" > "$work/rootfs.txt"
  exclude_rootfs_owned "$work/raw_over.txt" "$work/rootfs.txt" "$work/over.txt"
  apply_carve_waivers "$work/under.txt" "$work/carve_waivers.txt" "$work/under_unwaived.txt"

  local owned_count carved_count over_count under_count under_unwaived_count
  owned_count=$(wc -l < "$work/owned.txt")
  carved_count=$(wc -l < "$work/carved.txt")
  over_count=$(wc -l < "$work/over.txt")
  under_count=$(wc -l < "$work/under.txt")
  under_unwaived_count=$(wc -l < "$work/under_unwaived.txt")

  echo "=== carve conformance: $module ==="
  echo "owned (package-derived, minus $base_module baseline): $owned_count files"
  echo "carved (manifest file_spec+mask+protected_spec):       $carved_count files"
  echo "over-inclusion (carved, not owned, not rootfs/):        $over_count files"
  echo "under-carve (owned, not carved):                        $under_count files ($under_unwaived_count unwaived)"

  local status=0
  if [ "$module" = "$base_module" ]; then
    echo "NOTE: $module is the base-os baseline module — over-inclusion is exempt by design (WARN only, never FAIL)."
    if [ "$over_count" -gt 0 ]; then
      echo "WARN: over-inclusion (informational only for $base_module):"
      awk '{print "  " $0}' "$work/over.txt" | head -20
      [ "$over_count" -gt 20 ] && echo "  ... and $((over_count - 20)) more"
    fi
  elif [ "$over_count" -gt 0 ]; then
    echo "FAIL: $over_count carved file(s) not owned by any of this module's packages (and not from its rootfs/ overlay):"
    awk '{print "  " $0}' "$work/over.txt" | head -20
    [ "$over_count" -gt 20 ] && echo "  ... and $((over_count - 20)) more"
    status=1
  fi

  if [ "$under_unwaived_count" -gt 0 ]; then
    echo "WARN: $under_unwaived_count owned file(s) not carved by manifest file_spec (add to file_spec, or waive via carve_waivers if intentional):"
    awk '{print "  " $0}' "$work/under_unwaived.txt" | head -20
    [ "$under_unwaived_count" -gt 20 ] && echo "  ... and $((under_unwaived_count - 20)) more"
  fi

  if [ "$status" -eq 0 ]; then
    echo "RESULT: PASS"
  else
    echo "RESULT: FAIL"
  fi
  rm -rf "$work"
  return "$status"
}

main() {
  [ $# -ge 1 ] || { usage >&2; die "missing subcommand (derive|conformance)"; }
  local sub="$1"; shift
  case "$sub" in
    derive)      cmd_derive "$@" ;;
    conformance) cmd_conformance "$@" ;;
    -h|--help)   usage; exit 0 ;;
    *) usage >&2; die "unknown subcommand: $sub" ;;
  esac
}

# Only run main when executed directly — sourcing this file (as
# test-derive-file-spec.sh does) makes every function above callable
# without triggering the CLI.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
