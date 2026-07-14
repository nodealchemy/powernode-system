#!/usr/bin/env bash
# shellcheck disable=SC2086
# ^ File-wide: several unquoted $MODULE expansions below (e.g.
#   modules/$MODULE/rootfs, /tmp/$MODULE.erofs) are verbatim from the
#   original inline workflow step. $MODULE is validated upstream by the
#   `discover` job's SLUG_RE (^[A-Za-z0-9._-]+$) before it ever reaches
#   this script, so it can never contain whitespace/glob characters —
#   unquoted expansion is safe. Left unquoted (rather than "fixed") to
#   keep this extraction byte-for-byte verbatim; a future increment can
#   revisit quoting style once native builds are live.
#
# stage2-carve.sh — Stage 2 of the platform module build pipeline: rsync
# filter carve (fat rootfs -> slim module rootfs) + mkfs.erofs (with the
# inc5 SOURCE_DATE_EPOCH/-T/-U determinism flags) + fsverity digest.
#
# Extracted VERBATIM (campaign 019f5885 inc6 — pure refactor, no logic
# changes) from the "Stage 2 — composer (rsync filter + mkfs.erofs +
# fs-verity)" step of .gitea/workflows/build-platform-modules.yaml: same
# commands, same order, same env semantics, same hardcoded /tmp/* scratch
# paths — so the .erofs + fsverity root this produces are byte-identical
# to the pre-refactor inline step. The workflow step is now a thin
# invocation of this script; a future on-node/native build (inc7+, driven
# by build-one-module.sh in this same directory) runs the identical script
# with no Gitea Actions context at all.
#
# Two values varied by workflow context in the original inline step, both
# threaded through as explicit CLI args below (never read from the
# process environment):
#   $MODULE       — was GITHUB_ENV-set by "Resolve build slot" (untouched);
#                   now --module. Populated into a same-named $MODULE
#                   variable so the body needed zero further text changes.
#   $GITHUB_SHA    — was read directly by the inline step (SOURCE_DATE_EPOCH
#                   via `git log -1 --format=%ct "$GITHUB_SHA"`, and the
#                   erofs UUID's uuidgen --name); now --sha, populated into
#                   a same-named $GITHUB_SHA variable for the same reason.
# One line is a genuine ADDITION (not present in the inline step): a `cd
# "$WORKSPACE"` at the top. The inline step never `cd`s explicitly because
# Gitea Actions defaults every `run:` step's cwd to $GITHUB_WORKSPACE — an
# implicit behavior this standalone script can't rely on, since
# `modules/$MODULE/rootfs` (the rootfs/ overlay) and `git log` (for
# SOURCE_DATE_EPOCH) are both relative to the checked-out repo root.
# Explicit --workspace + `cd` replaces that implicit default; everything
# else below this line is unchanged.
# Every /tmp/* path (rsync_spec.txt input, fat/slim scratch trees, the
# .erofs + .erofs.meta outputs) is the SAME hardcoded literal the inline
# step used — not parameterized, since none of them are sourced from
# Actions context; they're the pipeline's existing shared-/tmp convention
# (the same container filesystem is shared by every step in a job),
# unchanged here.
#
# Usage:
#   stage2-carve.sh --module MODULE --sha SHA --workspace DIR
#
# Required:
#   --module MODULE       module slug
#   --sha SHA              commit SHA being built (was $GITHUB_SHA)
#   --workspace DIR         checked-out repo root (was the implicit
#                          $GITHUB_WORKSPACE cwd) — this script `cd`s here
#                          before reading modules/$MODULE/rootfs or running
#                          `git log`
#
# Reads:  /tmp/rsync_spec.txt (produced by the workflow's untouched "Parse
#         manifest" step), /tmp/fat (Stage 1.5's output),
#         modules/$MODULE/rootfs/ (relative to --workspace)
# Writes: /tmp/slim (the carved rootfs), /tmp/$MODULE.erofs,
#         /tmp/$MODULE.erofs.meta (fsverity_root= + size= key=value pairs)
#
# Exit: non-zero on any rsync/mkfs.erofs/fsverity failure (set -euo
# pipefail propagates the first one).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: stage2-carve.sh --module MODULE --sha SHA --workspace DIR

Stage 2 of the module build pipeline: rsync-filter carve + mkfs.erofs +
fsverity digest. See the file header for the full option reference and
the workflow-env-var mapping.
EOF
}

die() {
  echo "stage2-carve.sh: error: $*" >&2
  exit 2
}

MODULE=""
GITHUB_SHA=""
WORKSPACE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --module)
      [ $# -ge 2 ] || die "--module requires an argument"
      MODULE="$2"; shift 2 ;;
    --sha)
      [ $# -ge 2 ] || die "--sha requires an argument"
      GITHUB_SHA="$2"; shift 2 ;;
    --workspace)
      [ $# -ge 2 ] || die "--workspace requires an argument"
      WORKSPACE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[ -n "$MODULE" ] || { usage >&2; die "--module is required"; }
[ -n "$GITHUB_SHA" ] || { usage >&2; die "--sha is required"; }
[ -n "$WORKSPACE" ] || { usage >&2; die "--workspace is required"; }

# Addition (not in the original inline step — see file header): the
# inline step relied on Gitea Actions' implicit run-step cwd
# ($GITHUB_WORKSPACE). This script has no such implicit context.
cd "$WORKSPACE"

# ---------------------------------------------------------------------------
# Everything below is VERBATIM from the workflow's Stage 2 step body —  no
# text changed. $MODULE/$GITHUB_SHA are now populated by the arg parsing
# above instead of the shell/GITHUB_ENV environment; every other reference
# (including all /tmp/* paths) is byte-for-byte identical to the inline
# step.
# ---------------------------------------------------------------------------

# 1. Layer the module's static rootfs/ contents onto the
# bootstrapped /tmp/fat. Anything in rootfs/ overrides the
# apt-installed equivalent — that's how a module customizes
# its package's defaults.
if [ -d "modules/$MODULE/rootfs" ]; then
  rsync -a modules/$MODULE/rootfs/ /tmp/fat/
fi
# 2. Apply rsync filter to carve the slim module rootfs
# from the fat tree. Same filter that the buildah-mounted
# flow used.
mkdir -p /tmp/slim
# Filter order matters: --filter args are evaluated in CLI order
# and FIRST MATCH WINS. The merge file ends with `- *` (exclude
# everything not matched by an earlier `+`); if loaded first,
# `- *` matches intermediate dirs like `opt/` by basename and
# rsync never recurses into them. `+ */` must come FIRST so all
# directories are kept, then the file rules carve the actual
# contents. Without this, every Class B erofs blob ships empty
# (4-8 KB filesystem with just the root dir).
#
# --prune-empty-dirs is the counter-balance: `+ */` is greedy
# and would otherwise leave the entire fat tree's directory
# skeleton in the slim carve (e.g. /var/lib/postgresql/16/main
# appears as an empty 19-subdir tree because postgres's apt
# post-install ran `pg_createcluster main 16` in /tmp/fat).
# mkfs.erofs --all-root then bakes those root-owned empty
# dirs into the read-only lower layer, and runtime chowns
# against them trigger overlayfs metacopy copy-up which
# requires CAP_SYS_ADMIN that systemd strips from per-service
# namespaces → EPERM. Pruning empty dirs after the file rules
# execute drops /var, /tmp, /home, etc. entirely — matching
# the manifest's intent ("/var omitted, data dir initializes
# on first boot into the overlay's writable upper layer").
rsync -a \
  --filter='+ */' \
  --filter='. /tmp/rsync_spec.txt' \
  --prune-empty-dirs \
  /tmp/fat/ /tmp/slim/
echo "=== Stage 2 carve result: /tmp/slim layout (first 40 dirs) ==="
# awk-based truncation (NOT `| head`) — under `set -o pipefail`,
# head exiting after N lines sends SIGPIPE upstream → sort/find
# exit 141 → pipefail trips → whole step fails with no real
# error. awk reads the entire stream, just prints the first N.
find /tmp/slim -maxdepth 4 -type d | sort | awk 'NR<=40'
echo "=== /tmp/slim file count ==="
find /tmp/slim -type f | wc -l
echo "=== /tmp/slim total size ==="
du -sh /tmp/slim 2>&1 | awk 'NR==1'
# 3. Layer the module's static rootfs/ contents on top
if [ -d "modules/$MODULE/rootfs" ]; then
  rsync -a modules/$MODULE/rootfs/ /tmp/slim/
fi
# 4. mkfs.erofs — universal read-only lower-dir.
#
# erofs has been in mainline kernel since 5.4 (2019) and is
# enabled in every distro we'd ever target — Ubuntu LTS 20.04+,
# Debian 11+, Rocky/Alma 9+, Fedora 36+, Amazon Linux 2023,
# Alpine. Replaces the earlier dual-format (composefs +
# squashfs) machinery with a single artifact: erofs is
# mounted directly via loop, supports fs-verity natively, and
# generally produces smaller images than squashfs at the same
# compression level thanks to tail-packing + chunked layout.
#
# -zlz4hc keeps decompression cheap (better than -zlzma for
# cold-start) while still ~30-40% smaller than uncompressed.
# --all-root keeps file ownership stable across CI runs +
# production hosts so fs-verity hashes match.
#
# Determinism clamp (campaign 019f5885 inc5): --all-root alone
# normalizes uid/gid but NOT timestamps or the filesystem UUID —
# without also pinning those, mkfs.erofs stamps the wall-clock
# build time onto every inode and a fresh random UUID into the
# superblock, so two builds of an UNCHANGED module (identical
# /tmp/slim contents) still produce different bytes and a
# different fs-verity root.
#
#   -T "$SOURCE_DATE_EPOCH" — fixes the build timestamp. Its
#     default mode (--all-time, confirmed via `mkfs.erofs --help`
#     in the debian:trixie-slim build container, erofs-utils
#     1.8.6) also applies to every file's mtime, not just the
#     superblock — --all-time is passed explicitly below so a
#     future erofs-utils release changing that default can't
#     silently reopen this gap. SOURCE_DATE_EPOCH is the built
#     commit's own commit date, so it's identical for every
#     rebuild of the same SHA and follows the well-known
#     SOURCE_DATE_EPOCH convention (reproducible-builds.org)
#     other tooling in this pipeline may come to rely on.
#   -U "$EROFS_UUID" — fixes the filesystem UUID to a value
#     deterministically derived (RFC 4122 v5 / sha1) from
#     module-name+built-sha, so it's stable across rebuilds of
#     the same commit, distinct per module, and distinct per
#     commit (no collisions across the build matrix or across
#     history) — never mkfs.erofs's own random default.
#
# Verified locally (2 builds of an unchanged source tree, >1s
# apart, both flags set): byte-for-byte identical .erofs output
# — see this increment's report for the exact repro.
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct "${GITHUB_SHA}")
export SOURCE_DATE_EPOCH
echo "[stage-2] SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (commit date of ${GITHUB_SHA})"
EROFS_UUID=$(uuidgen --sha1 --namespace @oid --name "${MODULE}@${GITHUB_SHA}")
echo "[stage-2] erofs UUID for ${MODULE}@${GITHUB_SHA}: ${EROFS_UUID}"
mkfs.erofs \
  -zlz4hc \
  --all-root \
  -T "$SOURCE_DATE_EPOCH" \
  --all-time \
  -U "$EROFS_UUID" \
  /tmp/$MODULE.erofs \
  /tmp/slim
EROFS_ROOT=$(fsverity digest --hash-alg=sha256 /tmp/$MODULE.erofs | awk '{print $1}')
EROFS_SIZE=$(stat -c%s /tmp/$MODULE.erofs)
{
  echo "fsverity_root=$EROFS_ROOT"
  echo "size=$EROFS_SIZE"
} > /tmp/$MODULE.erofs.meta
