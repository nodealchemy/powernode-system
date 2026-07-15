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
# Derivation modes (--mode, both subcommands; default: fat-root):
#
#   fat-root      The original technique described above: OWNED is
#                computed via dpkg-query -L against a REAL mmdebstrap-built
#                fat rootfs (--fat-root). Highest fidelity — this IS what
#                the module actually ships (maintainer-script-generated
#                files, update-alternatives symlinks, triggers, everything
#                a real `dpkg -L` + install would produce) — but requires
#                an unprivileged-userns-capable mmdebstrap environment (a
#                builder). This is the land-gate mode.
#
#   deb-payload   Campaign 019f6084 P0-B: derives OWNED (and, for
#                conformance, CARVED) without ANY fat rootfs, so it runs
#                anywhere apt egress + dpkg-deb work — no privileged
#                mmdebstrap chroot needed — unblocking file_spec
#                correction/derivation without a builder fleet. Resolves
#                MODULE's (and --base-module's) package_spec closure via
#                `apt-get install --download-only --no-install-recommends`
#                against a private, throwaway APT state dir (no root
#                required) pointed at the manifest's pinned
#                build.apt_snapshot — the SAME snapshot.ubuntu.com mirror
#                stage1-rootfs.sh pins to, for the same determinism reason,
#                with the same "none" -> live archive.ubuntu.com fallback.
#                Each resolved .deb's OWN recorded payload (`dpkg-deb
#                --fsys-tarfile | tar -tf -`) stands in for a real dpkg
#                database's -L output — a package's .deb payload IS the
#                file list `dpkg -L` reports once it's installed, modulo
#                usr-merge canonicalization (see usr_merge_canonicalize;
#                every Noble .deb payload inspected while building this
#                mode already ships under /usr/... directly, so in
#                practice this is a defensive no-op today, not
#                load-bearing). OWNED = union(payload of MODULE's resolved
#                closure) − union(payload of --base-module's resolved
#                closure) (see resolve_debpayload_payloads). CARVED is
#                computed the same way minus the real filesystem: the
#                manifest's mask/file_spec/protected_spec globs are matched
#                directly against MODULE's own payload closure (the
#                candidate universe a real fat rootfs would otherwise
#                provide) via bash `case` pattern matching instead of
#                rsync --dry-run against a directory (see
#                expand_filter_over_candidates) — so `conformance --mode
#                deb-payload` runs the IDENTICAL carved-vs-owned diff this
#                file's header already documents, just with both sides
#                sourced from .deb payloads instead of a mounted tree.
#
#                Fidelity blind spots vs a real fat rootfs / dpkg -L
#                (inherent to reading .deb payloads instead of an installed
#                dpkg database — the same class of gap this pipeline's
#                mask:/rootfs: carving already works around for OTHER
#                reasons, not new to this mode):
#                  - maintainer-script-generated files (postinst/postrm
#                    writing config at install time — e.g.
#                    systemd-machine-id-setup, ssh-keygen; see
#                    base-os-ubuntu-noble/manifest.yaml's mask: comment for
#                    the two concrete cases this pipeline already masks)
#                  - update-alternatives symlinks (registered by postinst,
#                    never shipped in the payload itself)
#                  - dpkg trigger output (e.g. the ldconfig cache, man-db
#                    index)
#                  - a third-party apt repo not mirrored by
#                    snapshot.ubuntu.com (e.g. the vector/gcsfuse
#                    --hook-directory sources stage1-rootfs.sh registers
#                    for log-forwarder-vector/storage-tools) won't resolve
#                    here; --apt-snapshot none/absent falls back to the
#                    live archive.ubuntu.com/universe mirror the same way
#                    stage1-rootfs.sh does, which doesn't help for vendor
#                    repos either
#                deb-payload is a fast, no-builder-required APPROXIMATION
#                for deriving/checking file_spec corrections; fat-root
#                remains the authoritative land gate.
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
#   derive-file-spec.sh derive --mode deb-payload --module MODULE
#                        --workspace DIR [--packages P1,P2,...]
#                        [--base-module SLUG] [--cache-dir DIR]
#
#   derive-file-spec.sh conformance --module MODULE --workspace DIR
#                        --fat-root DIR [--packages-dir DIR]
#                        [--base-module SLUG]
#
#   derive-file-spec.sh conformance --mode deb-payload --module MODULE
#                        --workspace DIR [--packages P1,P2,...]
#                        [--base-module SLUG] [--cache-dir DIR]
#
# derive:
#   --module MODULE       module slug (matches a $MODULE.packages.txt in
#                          --packages-dir, as written by stage1-rootfs.sh —
#                          --mode fat-root only)
#   --mode MODE            fat-root (default) or deb-payload — see
#                          "Derivation modes" above
#   --fat-root DIR         [--mode fat-root] the built fat rootfs directory
#                          (dpkg admindir is DIR/var/lib/dpkg) — /tmp/fat in
#                          the real pipeline, a fixture tree in tests
#   --packages-dir DIR     [--mode fat-root] dir holding $MODULE.packages.txt
#                          files (default: /tmp, matching stage1-rootfs.sh's
#                          hardcoded output path)
#   --workspace DIR         [--mode deb-payload] checked-out repo root —
#                          see the naming note above; reads
#                          modules/$MODULE/manifest.yaml (and
#                          --base-module's) for package_spec +
#                          build.apt_snapshot
#   --packages P1,P2,...    [--mode deb-payload] comma-separated override
#                          of MODULE's resolved package list instead of
#                          reading package_spec from its manifest
#                          (--base-module's package list is always
#                          manifest-driven, no override)
#   --cache-dir DIR         [--mode deb-payload] reuse a persistent private
#                          apt-state + downloaded-.deb cache across
#                          invocations (default: a throwaway mktemp -d,
#                          removed before returning) — speeds up deriving
#                          several modules against the same --base-module
#                          closure back-to-back (campaign 019f6084 P0-C);
#                          see apt_fetch_closure's staleness caveat if
#                          reusing a cache-dir for the SAME module after
#                          editing its package_spec
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
#                          above (required for both modes: manifest +
#                          rootfs/ overlay live here regardless of mode)
#   --mode MODE             see derive
#   --fat-root DIR          [--mode fat-root] see derive
#   --packages-dir DIR      [--mode fat-root] see derive
#   --packages P1,P2,...    [--mode deb-payload] see derive
#   --cache-dir DIR         [--mode deb-payload] see derive
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

  derive-file-spec.sh derive --mode deb-payload --module MODULE
                       --workspace DIR [--packages P1,P2,...]
                       [--base-module SLUG] [--cache-dir DIR]

  derive-file-spec.sh conformance --module MODULE --workspace DIR
                       --fat-root DIR [--packages-dir DIR]
                       [--base-module SLUG]

  derive-file-spec.sh conformance --mode deb-payload --module MODULE
                       --workspace DIR [--packages P1,P2,...]
                       [--base-module SLUG] [--cache-dir DIR]

See the file header for the full option reference and semantics.
EOF
}

# =============================================================================
# Pure functions — operate only on their arguments + plain files; safe to
# unit-test directly (see tests/module-build/test-derive-file-spec.sh).
# =============================================================================

# set_subtract A_FILE B_FILE
# Lines in A_FILE not present in B_FILE (comm -23). Both inputs must
# already be LC_ALL=C sorted. `comm` itself is run under LC_ALL=C too —
# without it, comm checks input sortedness against the INVOKING shell's
# locale (e.g. en_US.UTF-8 here), which collates differently than the
# LC_ALL=C sort that produced these files; on real-world data (confirmed
# against deb-payload mode's actual apt-resolved file lists — see this
# increment's report) that mismatch makes comm both misreport "not in
# sorted order" AND exit non-zero, tripping this file's `set -e`. Generic
# set-difference shared by owned_package_names (package-NAME diff,
# fat-root mode) and resolve_debpayload_payloads (file-PATH diff,
# deb-payload mode) — campaign 019f6084 P0-B factored this out so both
# modes share one set-subtraction implementation.
set_subtract() {
  local a_file="$1" b_file="$2"
  LC_ALL=C comm -23 "$a_file" "$b_file"
}

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
  set_subtract "$pkg_names" "$base_names"
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
# paths. `comm` is run under LC_ALL=C too — see set_subtract's comment for
# why (a locale mismatch between the sort that produced these files and
# the comm that compares them makes comm misreport unsortedness and exit
# non-zero, surfaced by deb-payload mode's real-world file counts).
# Writes carved-but-not-owned (raw over-inclusion candidates, BEFORE the
# rootfs/ exclusion) to OUT_RAW_OVER, and owned-but-not-carved (under-carve
# candidates) to OUT_UNDER.
diff_report() {
  local owned="$1" carved="$2" out_raw_over="$3" out_under="$4"
  LC_ALL=C comm -13 "$owned" "$carved" > "$out_raw_over"  # in carved, not owned
  LC_ALL=C comm -23 "$owned" "$carved" > "$out_under"     # in owned, not carved
}

# exclude_rootfs_owned RAW_OVER_FILE ROOTFS_FILES_FILE OUT_FILE
# Drops entries present in ROOTFS_FILES_FILE from RAW_OVER_FILE — see
# rootfs_files' header comment for why. Both inputs must be LC_ALL=C
# sorted; comm runs under LC_ALL=C too (see set_subtract's comment).
exclude_rootfs_owned() {
  local raw_over="$1" rootfs="$2" out_file="$3"
  LC_ALL=C comm -23 "$raw_over" "$rootfs" > "$out_file"
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

# usr_merge_canonicalize IN_FILE
# Rewrites legacy pre-usrmerge top-level paths (/bin, /sbin, /lib, /lib64)
# in IN_FILE to their canonical usr-merged form (/usr/bin, /usr/sbin,
# /usr/lib, /usr/lib64), so deb-payload mode's payload listing compares
# equal to `dpkg -L` on a real Noble install (where /bin etc. are
# base-files-provided symlinks into /usr/, and a package's OWN payload is
# recorded — and therefore reported by dpkg -L — under the merged /usr/...
# path). Every Noble .deb payload inspected while building this mode
# (bash, coreutils, util-linux, libc6, qemu-guest-agent) already ships
# under /usr/... directly, so this is a defensive no-op for the common
# case today, not load-bearing — it protects against any future or legacy
# package that still ships an un-merged path. LC_ALL=C sorted,
# de-duplicated, to stdout.
usr_merge_canonicalize() {
  local in_file="$1"
  sed -e 's#^/bin/#/usr/bin/#' \
      -e 's#^/sbin/#/usr/sbin/#' \
      -e 's#^/lib64/#/usr/lib64/#' \
      -e 's#^/lib/#/usr/lib/#' \
      "$in_file" \
  | LC_ALL=C sort -u
}

# deb_payload_files DEB_FILE
# Lists DEB_FILE's payload — the file manifest a real dpkg database's
# `dpkg -L` reports for the same package/version once installed (see the
# file header's deb-payload fidelity note for where the two diverge).
# `dpkg-deb --fsys-tarfile | tar -tf -` lists every payload entry with a
# leading "./"; directories get a trailing "/", files and symlinks never
# do, so `grep -v '/$'` keeps exactly the files+symlinks (the same "drop
# directory entries" intent owned_files_for_packages applies on the
# fat-root side). Strips the leading "." (leaving the absolute "/..."
# dpkg -L convention), usr-merge-canonicalizes, LC_ALL=C sorts unique, to
# stdout.
deb_payload_files() {
  local deb_file="$1"
  local raw
  raw=$(mktemp)
  dpkg-deb --fsys-tarfile "$deb_file" | tar -tf - \
    | grep -v '/$' \
    | sed -e 's#^\.##' \
    > "$raw"
  usr_merge_canonicalize "$raw"
  rm -f "$raw"
}

# payload_files_for_debs DEBS_DIR
# Union of deb_payload_files over every *.deb directly inside DEBS_DIR
# (non-recursive — matches apt-get download's flat Dir::Cache::archives
# layout). Empty output (not an error) when DEBS_DIR has no .deb files.
# LC_ALL=C sorted, de-duplicated, to stdout.
payload_files_for_debs() {
  local debs_dir="$1"
  ( shopt -s nullglob
    local deb
    for deb in "$debs_dir"/*.deb; do
      deb_payload_files "$deb"
    done
  ) | LC_ALL=C sort -u
}

# expand_filter_over_candidates CANDIDATES_FILE FILTER_FILE
# Filesystem-free analog of carved_files: applies FILTER_FILE (as built by
# build_rsync_carve_filter — "- glob"/"+ glob" lines, first-match-wins,
# trailing "- *") to each path in CANDIDATES_FILE via bash `case` pattern
# matching instead of rsync --dry-run against a real directory tree. Used
# by deb-payload mode's conformance, which has no fat rootfs to rsync
# against — CANDIDATES_FILE is instead the module's OWN full deb-payload
# closure (see resolve_debpayload_payloads), the same "everything this
# module's own fat rootfs would contain" universe carved_files walks in
# fat-root mode. No directory-traversal concerns here (unlike
# carved_files' leading "+ */" rule) — CANDIDATES_FILE is already a flat
# file list, not a tree to recurse into. Same "**" behaves as "*"
# case-pattern relaxation as apply_carve_waivers (case patterns aren't
# slash-aware to begin with). Both inputs must already be LC_ALL=C sorted;
# output is LC_ALL=C sorted to stdout.
expand_filter_over_candidates() {
  local candidates_file="$1" filter_file="$2"
  {
    local path rule action glob
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        action="${rule:0:1}"
        glob="${rule:2}"
        # shellcheck disable=SC2254  # intentionally unquoted: $glob must
        # be interpreted as a case pattern, not a literal string.
        case "$path" in
          $glob)
            [ "$action" = "+" ] && echo "$path"
            break
            ;;
        esac
      done < "$filter_file"
    done < "$candidates_file"
  } | LC_ALL=C sort -u
}

# =============================================================================
# Network resolution (deb-payload mode only) — the ONLY functions in this
# file that touch apt or the network. Everything above this line is pure
# (fixture-testable, no network); everything below fetches real packages
# from a snapshot.ubuntu.com (or, for apt_snapshot none/absent, live
# archive.ubuntu.com) mirror. See the file header's "Derivation modes"
# section for why this mode exists and its fidelity blind spots.
# =============================================================================

# module_package_spec WORKSPACE MODULE OUT_FILE
# Writes MODULE's manifest.yaml package_spec entries (one per line) to
# OUT_FILE — the same `jq -r '.package_spec[]?'` extraction
# .gitea/workflows/build-platform-modules.yaml's "Parse manifest" step (and
# transitively stage1-rootfs.sh's --include list) use. Dies if the
# manifest is missing.
module_package_spec() {
  local workspace="$1" module="$2" out_file="$3"
  local mfpath="$workspace/modules/$module/manifest.yaml"
  [ -f "$mfpath" ] || die "no manifest at $mfpath"
  local tmp_json
  tmp_json=$(mktemp)
  manifest_to_json "$mfpath" "$tmp_json"
  jq -r '.package_spec[]?' "$tmp_json" > "$out_file"
  rm -f "$tmp_json"
}

# module_apt_snapshot WORKSPACE MODULE
# Echoes MODULE's manifest.yaml build.apt_snapshot value, or "none" if
# absent/null — the same normalization stage1-rootfs.sh's --apt-snapshot
# expects (its documented per-module opt-out to the live mirror).
module_apt_snapshot() {
  local workspace="$1" module="$2"
  local mfpath="$workspace/modules/$module/manifest.yaml"
  [ -f "$mfpath" ] || die "no manifest at $mfpath"
  local tmp_json
  tmp_json=$(mktemp)
  manifest_to_json "$mfpath" "$tmp_json"
  jq -r '.build.apt_snapshot // "none"' "$tmp_json"
  rm -f "$tmp_json"
}

# apt_fetch_closure CACHE_DIR APT_SNAPSHOT ARCHIVES_DIR PACKAGE...
# Resolves PACKAGE...'s full transitive Depends closure at APT_SNAPSHOT
# (snapshot.ubuntu.com/ubuntu/$APT_SNAPSHOT, or live archive.ubuntu.com/
# ubuntu when APT_SNAPSHOT is "none"/empty — the identical base_url choice
# stage1-rootfs.sh makes for the same package set) and downloads every
# resolved .deb into ARCHIVES_DIR — the SAME apt dependency solver
# mmdebstrap itself uses internally, applied standalone via `apt-get
# install --download-only --no-install-recommends` (--no-install-recommends
# to match mmdebstrap's --variant=minbase, which also pulls Depends only,
# never Recommends) against a private, throwaway APT_CONFIG +
# Dir::Etc/Dir::State/Dir::Cache/Dir::State::status tree — no root
# required, no write to the real /etc/apt or /var/lib/apt/lists.
#
# APT_CONFIG (rather than just -o Dir::Etc=...) is required to keep this
# hermetic: apt's initial config-directory scan (the REAL /etc/apt/apt.conf.d/*,
# which can carry host-local hooks entirely unrelated to this pipeline —
# empirically, a dev box building this mode had a stray KDE-neon apt hook
# that tries to symlink into the real /etc/apt/preferences.d and fails
# unprivileged) runs BEFORE command-line -o overrides are applied, so only
# a pre-scan APT_CONFIG override (setting Dir::Etc::parts to an empty
# private directory) can suppress it — confirmed empirically, see this
# increment's report for the exact repro.
#
# CACHE_DIR is reused across calls: an `apt-get update` per distinct
# APT_SNAPSHOT value is skipped via a marker file once its lists are
# fresh, so deriving several modules against the same --base-module
# back-to-back doesn't re-fetch the same Packages indices every time.
# ARCHIVES_DIR itself is NOT cleared between calls — reusing the same
# CACHE_DIR for the SAME module after editing its package_spec can leave
# stale .debs behind (payload_files_for_debs would then union in packages
# no longer declared); use a fresh --cache-dir, or delete its
# archives/$MODULE subdir, after such edits.
#
# A DERIVE_FILE_SPEC_TEST_DEB_SRC escape hatch (test-only — unset in every
# real invocation) short-circuits the network entirely: when set, it must
# point at a directory of pre-built fixture PACKAGE.deb files (see
# tests/module-build/test-derive-file-spec.sh), which are copied into
# ARCHIVES_DIR instead of resolving/downloading anything — this is how the
# deb-payload conformance red/green cases are exercised hermetically,
# without real apt/network access.
apt_fetch_closure() {
  local cache_dir="$1" apt_snapshot="$2" archives_dir="$3"; shift 3
  local pkgs=("$@")
  mkdir -p "$archives_dir"
  [ "${#pkgs[@]}" -gt 0 ] || return 0

  if [ -n "${DERIVE_FILE_SPEC_TEST_DEB_SRC:-}" ]; then
    local pkg
    for pkg in "${pkgs[@]}"; do
      [ -f "$DERIVE_FILE_SPEC_TEST_DEB_SRC/$pkg.deb" ] \
        || die "DERIVE_FILE_SPEC_TEST_DEB_SRC set but no fixture .deb for '$pkg' at $DERIVE_FILE_SPEC_TEST_DEB_SRC/$pkg.deb"
      cp "$DERIVE_FILE_SPEC_TEST_DEB_SRC/$pkg.deb" "$archives_dir/"
    done
    return 0
  fi

  mkdir -p "$cache_dir/etc/apt/apt.conf.d" "$cache_dir/etc/apt/sources.list.d" \
           "$cache_dir/etc/apt/preferences.d" "$cache_dir/var/lib/apt/lists/partial" \
           "$cache_dir/var/lib/dpkg" "$archives_dir/partial"
  [ -f "$cache_dir/var/lib/dpkg/status" ] || : > "$cache_dir/var/lib/dpkg/status"
  [ -f "$cache_dir/apt.conf" ] || printf 'Dir::Etc::parts "%s";\n' "$cache_dir/etc/apt/apt.conf.d" > "$cache_dir/apt.conf"

  local snapshot_key="${apt_snapshot:-none}" base_url
  if [ -n "$apt_snapshot" ] && [ "$apt_snapshot" != "none" ]; then
    base_url="https://snapshot.ubuntu.com/ubuntu/${apt_snapshot}/"
  else
    base_url="http://archive.ubuntu.com/ubuntu/"
  fi
  printf 'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] %s noble main universe\n' \
    "$base_url" > "$cache_dir/etc/apt/sources.list.d/snapshot.list"

  local marker="$cache_dir/.apt-updated-${snapshot_key}"
  if [ ! -f "$marker" ]; then
    # >&2 on both apt-get calls below: apt writes its own normal progress
    # output (Get:/Fetched:/Reading package lists...) to STDOUT by
    # default, not stderr — left alone, that chatter would land in the
    # SAME stream as this tool's actual contract (derive prints the
    # owned-file list to stdout; conformance prints its report there).
    # Redirecting apt's stdout to stderr keeps ours clean while still
    # surfacing every line (including real apt errors, which already go
    # to stderr) for die()'s "see output above" to point at. Confirmed
    # empirically: without this, a live run's stdout was contaminated
    # with "Get:1 https://snapshot.ubuntu.com/..." lines ahead of the
    # actual owned-file paths — see this increment's report.
    APT_CONFIG="$cache_dir/apt.conf" apt-get \
      -o Dir::Etc="$cache_dir/etc/apt" \
      -o Dir::State="$cache_dir/var/lib/apt" \
      -o Dir::Cache="$cache_dir/var/cache/apt" \
      -o Dir::State::status="$cache_dir/var/lib/dpkg/status" \
      update >&2 \
      || die "apt-get update failed against $base_url (apt_snapshot=$snapshot_key) — see output above"
    : > "$marker"
  fi

  APT_CONFIG="$cache_dir/apt.conf" apt-get \
    -o Dir::Etc="$cache_dir/etc/apt" \
    -o Dir::State="$cache_dir/var/lib/apt" \
    -o Dir::Cache::archives="$archives_dir" \
    -o Dir::State::status="$cache_dir/var/lib/dpkg/status" \
    install --download-only --no-install-recommends -y "${pkgs[@]}" >&2 \
    || die "apt-get install --download-only failed for: ${pkgs[*]} (apt_snapshot=$snapshot_key) — see output above"
}

# resolve_debpayload_payloads WORKSPACE MODULE BASE_MODULE CACHE_DIR
#                              PKGS_OVERRIDE_FILE OUT_MODULE_PAYLOAD OUT_OWNED
# Fetches MODULE's (or, if PKGS_OVERRIDE_FILE is a non-empty string naming
# a file, that file's newline-delimited package list instead of reading
# package_spec) and BASE_MODULE's resolved closures via apt_fetch_closure,
# writes MODULE's full payload (union of deb_payload_files across its
# closure) to OUT_MODULE_PAYLOAD, and the owned set to OUT_OWNED: ALL of
# MODULE's payload when MODULE equals BASE_MODULE (no baseline to subtract
# — the same base-module special case resolve_owned_packages applies in
# fat-root mode), otherwise set_subtract(MODULE payload, BASE_MODULE
# payload).
resolve_debpayload_payloads() {
  local workspace="$1" module="$2" base_module="$3" cache_dir="$4"
  local pkgs_override_file="$5" out_module_payload="$6" out_owned="$7"

  local module_pkgs_file module_pkgs_owned=0
  if [ -n "$pkgs_override_file" ]; then
    module_pkgs_file="$pkgs_override_file"
  else
    module_pkgs_file=$(mktemp)
    module_pkgs_owned=1
    module_package_spec "$workspace" "$module" "$module_pkgs_file"
  fi
  local module_snapshot module_archives
  module_snapshot=$(module_apt_snapshot "$workspace" "$module")
  module_archives="$cache_dir/archives/$module"
  local module_pkg_list=() pkg
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    module_pkg_list+=("$pkg")
  done < "$module_pkgs_file"
  apt_fetch_closure "$cache_dir" "$module_snapshot" "$module_archives" "${module_pkg_list[@]}"
  payload_files_for_debs "$module_archives" > "$out_module_payload"
  [ "$module_pkgs_owned" -eq 1 ] && rm -f "$module_pkgs_file"

  if [ "$module" = "$base_module" ]; then
    cp "$out_module_payload" "$out_owned"
    return 0
  fi

  local base_pkgs_file base_snapshot base_archives base_payload
  base_pkgs_file=$(mktemp)
  module_package_spec "$workspace" "$base_module" "$base_pkgs_file"
  base_snapshot=$(module_apt_snapshot "$workspace" "$base_module")
  base_archives="$cache_dir/archives/$base_module"
  local base_pkg_list=()
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    base_pkg_list+=("$pkg")
  done < "$base_pkgs_file"
  apt_fetch_closure "$cache_dir" "$base_snapshot" "$base_archives" "${base_pkg_list[@]}"
  base_payload=$(mktemp)
  payload_files_for_debs "$base_archives" > "$base_payload"
  set_subtract "$out_module_payload" "$base_payload" > "$out_owned"
  rm -f "$base_pkgs_file" "$base_payload"
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
  local mode="fat-root" workspace="" packages_override="" cache_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --module)       [ $# -ge 2 ] || die "--module requires an argument";       module="$2"; shift 2 ;;
      --fat-root)     [ $# -ge 2 ] || die "--fat-root requires an argument";     fat_root="$2"; shift 2 ;;
      --packages-dir) [ $# -ge 2 ] || die "--packages-dir requires an argument"; packages_dir="$2"; shift 2 ;;
      --base-module)  [ $# -ge 2 ] || die "--base-module requires an argument";  base_module="$2"; shift 2 ;;
      --mode)         [ $# -ge 2 ] || die "--mode requires an argument";         mode="$2"; shift 2 ;;
      --workspace)    [ $# -ge 2 ] || die "--workspace requires an argument";    workspace="$2"; shift 2 ;;
      --packages)     [ $# -ge 2 ] || die "--packages requires an argument";     packages_override="$2"; shift 2 ;;
      --cache-dir)    [ $# -ge 2 ] || die "--cache-dir requires an argument";    cache_dir="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$module" ] || die "--module is required"

  case "$mode" in
    fat-root)
      [ -n "$fat_root" ] || die "--fat-root is required for --mode fat-root"
      [ -d "$fat_root" ] || die "--fat-root '$fat_root' is not a directory"

      # No `trap ... EXIT` here on purpose: a trap string referencing a
      # function-`local` variable is expanded when the trap FIRES, which
      # for an EXIT trap is after this function (and its local scope) has
      # already returned — that reliably hits `set -u` as an "unbound
      # variable" error. Explicit cleanup at every return point instead
      # (matches this script family's existing style —
      # stage1-rootfs.sh/stage2-carve.sh don't use traps either).
      local work
      work=$(mktemp -d)

      resolve_owned_packages "$module" "$base_module" "$packages_dir" "$work/owned_pkgs.txt"
      owned_files_for_packages "$fat_root" "$work/owned_pkgs.txt"
      rm -rf "$work"
      ;;
    deb-payload)
      cmd_derive_deb_payload "$module" "$base_module" "$workspace" "$packages_override" "$cache_dir"
      ;;
    *) die "unknown --mode: $mode (expected fat-root or deb-payload)" ;;
  esac
}

# cmd_derive_deb_payload MODULE BASE_MODULE WORKSPACE PACKAGES_OVERRIDE CACHE_DIR
# `derive --mode deb-payload` body — see resolve_debpayload_payloads for
# the mechanics. PACKAGES_OVERRIDE and CACHE_DIR may be empty strings
# (defaults: read package_spec from the manifest; a throwaway mktemp -d
# removed before returning).
cmd_derive_deb_payload() {
  local module="$1" base_module="$2" workspace="$3" packages_override="$4" cache_dir="$5"
  [ -n "$workspace" ] || die "--workspace is required for --mode deb-payload"
  [ -d "$workspace" ] || die "--workspace '$workspace' is not a directory"

  local cache_owned=0
  if [ -z "$cache_dir" ]; then
    cache_dir=$(mktemp -d)
    cache_owned=1
  fi
  local pkgs_override_file=""
  if [ -n "$packages_override" ]; then
    pkgs_override_file=$(mktemp)
    tr ',' '\n' <<< "$packages_override" | sed '/^$/d' > "$pkgs_override_file"
  fi

  local work
  work=$(mktemp -d)
  resolve_debpayload_payloads "$workspace" "$module" "$base_module" "$cache_dir" \
    "$pkgs_override_file" "$work/module_payload.txt" "$work/owned.txt"
  cat "$work/owned.txt"
  rm -rf "$work"

  [ -z "$pkgs_override_file" ] || rm -f "$pkgs_override_file"
  [ "$cache_owned" -eq 1 ] && rm -rf "$cache_dir"
  return 0
}

cmd_conformance() {
  local module="" workspace="" fat_root="" packages_dir="/tmp" base_module="base-os-ubuntu-noble"
  local mode="fat-root" packages_override="" cache_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --module)       [ $# -ge 2 ] || die "--module requires an argument";       module="$2"; shift 2 ;;
      --workspace)    [ $# -ge 2 ] || die "--workspace requires an argument";    workspace="$2"; shift 2 ;;
      --fat-root)     [ $# -ge 2 ] || die "--fat-root requires an argument";     fat_root="$2"; shift 2 ;;
      --packages-dir) [ $# -ge 2 ] || die "--packages-dir requires an argument"; packages_dir="$2"; shift 2 ;;
      --base-module)  [ $# -ge 2 ] || die "--base-module requires an argument";  base_module="$2"; shift 2 ;;
      --mode)         [ $# -ge 2 ] || die "--mode requires an argument";         mode="$2"; shift 2 ;;
      --packages)     [ $# -ge 2 ] || die "--packages requires an argument";     packages_override="$2"; shift 2 ;;
      --cache-dir)    [ $# -ge 2 ] || die "--cache-dir requires an argument";    cache_dir="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$module" ]    || die "--module is required"
  [ -n "$workspace" ] || die "--workspace is required"
  [ -d "$workspace" ] || die "--workspace '$workspace' is not a directory"

  local mfpath="$workspace/modules/$module/manifest.yaml"
  [ -f "$mfpath" ] || die "no manifest at $mfpath"

  # See cmd_derive's comment: no EXIT trap here — explicit cleanup at the
  # return points below instead.
  local work
  work=$(mktemp -d)

  # --- carve filter (manifest file_spec + mask + protected_spec — mode
  #     independent, same rsync filter shape stage2-carve.sh's Stage 2
  #     carve uses either way) ---
  manifest_to_json "$mfpath" "$work/manifest.json"
  jq -r '.mask[]?'           "$work/manifest.json" > "$work/mask.txt"
  jq -r '.file_spec[]?'      "$work/manifest.json" > "$work/file_spec.txt"
  jq -r '.protected_spec[]?' "$work/manifest.json" > "$work/protected_spec.txt"
  jq -r '.carve_waivers[]?'  "$work/manifest.json" > "$work/carve_waivers.txt"
  build_rsync_carve_filter "$work/mask.txt" "$work/file_spec.txt" "$work/protected_spec.txt" "$work/filter.txt"

  # --- owned + carved sets (mode dependent — see the file header's
  #     "Derivation modes" section) ---
  local cache_owned=0 pkgs_override_file=""
  case "$mode" in
    fat-root)
      [ -n "$fat_root" ] || die "--fat-root is required for --mode fat-root"
      [ -d "$fat_root" ] || die "--fat-root '$fat_root' is not a directory"
      carved_files "$fat_root" "$work/filter.txt" > "$work/carved.txt"
      resolve_owned_packages "$module" "$base_module" "$packages_dir" "$work/owned_pkgs.txt"
      owned_files_for_packages "$fat_root" "$work/owned_pkgs.txt" > "$work/owned.txt"
      ;;
    deb-payload)
      if [ -z "$cache_dir" ]; then
        cache_dir=$(mktemp -d)
        cache_owned=1
      fi
      if [ -n "$packages_override" ]; then
        pkgs_override_file=$(mktemp)
        tr ',' '\n' <<< "$packages_override" | sed '/^$/d' > "$pkgs_override_file"
      fi
      resolve_debpayload_payloads "$workspace" "$module" "$base_module" "$cache_dir" \
        "$pkgs_override_file" "$work/module_payload.txt" "$work/owned.txt"
      expand_filter_over_candidates "$work/module_payload.txt" "$work/filter.txt" > "$work/carved.txt"
      ;;
    *) die "unknown --mode: $mode (expected fat-root or deb-payload)" ;;
  esac

  # --- diff + rootfs/ exclusion + waivers (mode independent) ---
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
  echo "mode: $mode"
  echo "owned (package-derived, minus $base_module baseline): $owned_count files"
  echo "carved (manifest file_spec+mask+protected_spec):       $carved_count files"
  echo "over-inclusion (carved, not owned, not rootfs/):        $over_count files"
  echo "under-carve (owned, not carved):                        $under_count files ($under_unwaived_count unwaived)"

  local status=0
  if [ "$module" = "$base_module" ]; then
    echo "NOTE: $module is the base-os baseline module — over-inclusion is exempt by design (WARN only, never FAIL)."
    if [ "$over_count" -gt 0 ]; then
      echo "WARN: over-inclusion (informational only for $base_module):"
      # awk-based truncation (NOT `| head -20`) — see stage2-carve.sh's
      # identical comment: under `set -o pipefail`, head exiting after N
      # lines sends SIGPIPE upstream, awk exits 141, pipefail trips, and
      # this whole function aborts under `set -e` with no real error.
      # Only bites when a list actually exceeds 20 lines — confirmed
      # against deb-payload mode's real-world over-inclusion counts (345
      # files for qemu-guest-agent's broad file_spec against base-os),
      # which is what surfaced this pre-existing bug; small fixture lists
      # never triggered it.
      awk '{print "  " $0}' "$work/over.txt" | awk 'NR<=20'
      [ "$over_count" -gt 20 ] && echo "  ... and $((over_count - 20)) more"
    fi
  elif [ "$over_count" -gt 0 ]; then
    echo "FAIL: $over_count carved file(s) not owned by any of this module's packages (and not from its rootfs/ overlay):"
    awk '{print "  " $0}' "$work/over.txt" | awk 'NR<=20'
    [ "$over_count" -gt 20 ] && echo "  ... and $((over_count - 20)) more"
    status=1
  fi

  if [ "$under_unwaived_count" -gt 0 ]; then
    echo "WARN: $under_unwaived_count owned file(s) not carved by manifest file_spec (add to file_spec, or waive via carve_waivers if intentional):"
    awk '{print "  " $0}' "$work/under_unwaived.txt" | awk 'NR<=20'
    [ "$under_unwaived_count" -gt 20 ] && echo "  ... and $((under_unwaived_count - 20)) more"
  fi

  if [ "$status" -eq 0 ]; then
    echo "RESULT: PASS"
  else
    echo "RESULT: FAIL"
  fi
  rm -rf "$work"
  [ -z "$pkgs_override_file" ] || rm -f "$pkgs_override_file"
  [ "$cache_owned" -eq 1 ] && rm -rf "$cache_dir"
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
