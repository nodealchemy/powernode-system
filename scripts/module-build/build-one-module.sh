#!/usr/bin/env bash
# build-one-module.sh — top-level driver: builds ONE module's fat rootfs +
# slim erofs at a checked-out SHA, end to end (Stage 1 -> Stage 1.5 ->
# Stage 2), by invoking the same stage1-rootfs.sh / stage15.sh /
# stage2-carve.sh scripts the Gitea workflow now calls as thin steps.
#
# New in campaign 019f5885 inc6 (this increment adds the driver; it does
# not extract from any single existing workflow step — see below).
#
# Why this exists: native builds (inc7+, an ephemeral on-node/CI-worker
# build with no Gitea Actions context at all) need to run the EXACT same
# build logic the Gitea workflow runs, without any of workflow-only
# machinery (matrix slots, step outputs, GITHUB_ENV, GITHUB_OUTPUT). This
# script is that single entry point: it replicates the workflow's "Parse
# manifest for the resolved module" step (VERBATIM logic — see the "Parse
# manifest replication" section below) since there is no separate Gitea
# step to produce /tmp/manifest.json / /tmp/package_spec.txt /
# /tmp/rsync_spec.txt on a native run, then calls the three stage scripts
# in order. It takes ONLY explicit CLI args — it never reads GITHUB_*
# or GITEA_* environment variables.
#
# It does NOT push (see push.sh, invoked separately — pushing is a later
# pipeline concern with its own credential-handling shape, not part of
# "build one module").
#
# It does NOT install build tooling (mmdebstrap, erofs-utils, fsverity,
# jq, rsync, python3-yaml, git, uuid-runtime, cosign, oras — see the
# workflow's "Install build tools" + "Install signing toolchain" steps,
# both left untouched/inline). The caller's environment (ephemeral
# instance image, or the Gitea build container) is expected to already
# have them; that provisioning story is out of scope for this increment.
#
# Usage:
#   PARENT_PAT=token build-one-module.sh --module MODULE --sha SHA
#                                         --workspace DIR
#                                         [--arch amd64|arm64]
#                                         [--parent-host HOST]
#                                         [--parent-path OWNER/REPO]
#
# Required:
#   --module MODULE        module slug (must have modules/MODULE/manifest.yaml
#                          under --workspace)
#   --sha SHA                commit SHA being built — threaded to
#                          stage2-carve.sh (SOURCE_DATE_EPOCH + erofs UUID)
#   --workspace DIR           checked-out repo root
#
# Optional:
#   --arch amd64|arm64        default: amd64 — threaded to stage15.sh
#   --parent-host HOST         default: git.powernode.org — threaded to
#                          stage15.sh (only consulted by the
#                          powernode-hub-backend/worker/frontend arms)
#   --parent-path OWNER/REPO  default: powernode/powernode-platform —
#                          threaded to stage15.sh (same arms as above)
#
# Env (optional, credential — see the crypto-material-safety note in
# stage15.sh's header; never pass as a CLI argument):
#   PARENT_PAT      PAT for cloning the parent powernode-platform repo
#                  (only consulted by the hub-backend/worker/frontend
#                  arms). Inherited automatically by stage15.sh as a
#                  subprocess (bash propagates env vars to children) — no
#                  explicit re-export needed.
#
# Outputs (same hardcoded /tmp/* contract the workflow's three stages
# already share):
#   /tmp/fat                    the assembled fat rootfs
#   /tmp/slim                   the carved slim rootfs
#   /tmp/MODULE.erofs             the final erofs image
#   /tmp/MODULE.erofs.meta        fsverity_root= + size= key=value pairs
#   /tmp/MODULE.packages.txt      resolved-package provenance (Stage 1)
#   /tmp/manifest.json, /tmp/package_spec.txt, /tmp/rsync_spec.txt
#                                this script's own manifest-parse output
#                                (see below)
#
# Exit: non-zero on any stage's failure (set -euo pipefail propagates the
# first one); this script's own manifest-parse step has the same FATAL
# guard shape (missing manifest.yaml -> clear error, not a cryptic yq/jq
# failure).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: PARENT_PAT=token build-one-module.sh --module MODULE --sha SHA
                                             --workspace DIR
                                             [--arch amd64|arm64]
                                             [--parent-host HOST]
                                             [--parent-path OWNER/REPO]

Builds one module's fat rootfs + slim erofs at a checked-out SHA by
running stage1-rootfs.sh -> stage15.sh -> stage2-carve.sh in order, with
no Gitea Actions context. Does not push (see push.sh). See the file
header for the full option reference.
EOF
}

die() {
  echo "build-one-module.sh: error: $*" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODULE=""
GITHUB_SHA=""
WORKSPACE=""
ARCH="amd64"
PARENT_HOST="git.powernode.org"
PARENT_PATH="powernode/powernode-platform"

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
    --arch)
      [ $# -ge 2 ] || die "--arch requires an argument"
      ARCH="$2"; shift 2 ;;
    --parent-host)
      [ $# -ge 2 ] || die "--parent-host requires an argument"
      PARENT_HOST="$2"; shift 2 ;;
    --parent-path)
      [ $# -ge 2 ] || die "--parent-path requires an argument"
      PARENT_PATH="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[ -n "$MODULE" ] || { usage >&2; die "--module is required"; }
[ -n "$GITHUB_SHA" ] || { usage >&2; die "--sha is required"; }
[ -n "$WORKSPACE" ] || { usage >&2; die "--workspace is required"; }

require_cmd jq
[ -d "$WORKSPACE" ] || die "--workspace '$WORKSPACE' is not a directory"
cd "$WORKSPACE"

mfpath="modules/$MODULE/manifest.yaml"
[ -f "$mfpath" ] || die "no $mfpath under --workspace '$WORKSPACE' — check the module slug"

# ---------------------------------------------------------------------------
# Parse manifest replication — VERBATIM logic from the workflow's own
# "Parse manifest for the resolved module" step (untouched in the
# workflow), reproduced here because a native run has no separate Gitea
# step to produce these files first. Same yq-preferred/python3-fallback
# shape, same three output files at the same hardcoded /tmp paths every
# stage script already expects, same apt_snapshot normalization to "none".
# The two `echo ... >> "$GITHUB_OUTPUT"` lines from the original step are
# replaced by using $snapshot directly below (no Gitea step-output
# mechanism exists here).
# ---------------------------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  yq -o=json '.' "$mfpath" > /tmp/manifest.json
else
  require_cmd python3
  python3 -c "import yaml,json,sys; json.dump(yaml.safe_load(open('$mfpath')), sys.stdout)" > /tmp/manifest.json
fi
jq -r '.package_spec[]?' /tmp/manifest.json > /tmp/package_spec.txt
{
  jq -r '.mask[]?' /tmp/manifest.json | awk '{print "- " $0}'
  jq -r '.file_spec[]?' /tmp/manifest.json | awk '{print "+ " $0}'
  jq -r '.protected_spec[]?' /tmp/manifest.json | awk '{print "+ " $0}'
  echo "- *"
} > /tmp/rsync_spec.txt
snapshot=$(jq -r '.build.apt_snapshot // "none"' /tmp/manifest.json)

echo "[build-one-module] module=$MODULE sha=$GITHUB_SHA apt_snapshot=$snapshot"

echo "[build-one-module] === Stage 1: rootfs bootstrap ==="
bash "$SCRIPT_DIR/stage1-rootfs.sh" --module "$MODULE" --apt-snapshot "$snapshot"

echo "[build-one-module] === Stage 1.5: parent content + agent cross-compile ==="
bash "$SCRIPT_DIR/stage15.sh" \
  --module "$MODULE" \
  --workspace "$WORKSPACE" \
  --arch "$ARCH" \
  --parent-host "$PARENT_HOST" \
  --parent-path "$PARENT_PATH"

echo "[build-one-module] === Stage 2: carve + mkfs.erofs + fsverity ==="
bash "$SCRIPT_DIR/stage2-carve.sh" --module "$MODULE" --sha "$GITHUB_SHA" --workspace "$WORKSPACE"

echo "[build-one-module] done: /tmp/$MODULE.erofs ($(stat -c%s "/tmp/$MODULE.erofs" 2>/dev/null || echo '?') bytes)"
