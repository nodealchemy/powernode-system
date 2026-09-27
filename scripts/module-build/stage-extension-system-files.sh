#!/usr/bin/env bash
# stage-extension-system-files.sh — the LOCAL, network-free half of
# stage15.sh's `powernode-extension-system` arm: stages this submodule's
# server/, config/, worker/ and extension.json into the module's fat rootfs
# shape. Extracted out of stage15.sh (IMP-fad0b3f67255) so this specific
# staging logic — the mechanism that silently dropped config/, wiring
# extensions/system/config/runbooks.yml missing on the deployed hub and
# System::Status::RemediationWiring#register_runbook_source! failing on
# every boot — is unit-testable without stage15.sh's OTHER half (the parent
# powernode-platform clone + dedicated-module frontend build), which needs
# network egress and is deliberately fail-hard with no fallback (see
# stage15.sh's own "DO NOT ADD A FALLBACK ARM" comment on that clone).
#
# stage15.sh's powernode-extension-system arm calls this script for exactly
# the four trees below, then continues inline with the worker-component log
# line and the frontend build. Nothing about ITS logic changed here — this
# is the same mkdir+rsync+cp sequence, verbatim, plus the config/ staging
# and the fail-loud checks this task adds.
#
# Usage:
#   stage-extension-system-files.sh --workspace DIR [--fat-root DIR]
#
# Required:
#   --workspace DIR   checked-out extension-system repo root (server/,
#                      config/, worker/, extension.json all read relative
#                      to this directory)
#
# Optional:
#   --fat-root DIR     the module's fat rootfs root. Default: /tmp/fat,
#                       stage15.sh's own hardcoded convention (see its file
#                       header — every /tmp/* path there is a shared,
#                       unparameterized convention, not an oversight).
#                       Overridable ONLY so this script is testable against
#                       a throwaway directory instead of the real build
#                       path; production callers should never pass this.
#
# Exit: non-zero (via `die`, itself `set -euo pipefail` under the hood) when
# a tree this module's runtime code actually reads (config/, worker/) is
# missing from the workspace, OR when config/runbooks.yml specifically did
# not land in the staged tree after the rsync that was supposed to ship it
# — the second check exists because "the rsync ran without error" and "the
# file is actually there" are not the same fact, and this bug's original
# form (config/ silently never in the rsync's OWN source-argument list) is
# exactly the class of gap where the rsync command itself never fails.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: stage-extension-system-files.sh --workspace DIR [--fat-root DIR]
EOF
}

die() {
  echo "stage-extension-system-files.sh: error: $*" >&2
  exit 2
}

WORKSPACE=""
FAT_ROOT="/tmp/fat"

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace)
      [ $# -ge 2 ] || die "--workspace requires an argument"
      WORKSPACE="$2"; shift 2 ;;
    --fat-root)
      [ $# -ge 2 ] || die "--fat-root requires an argument"
      FAT_ROOT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[ -n "$WORKSPACE" ] || { usage >&2; die "--workspace is required"; }

EXT_ROOT="$FAT_ROOT/opt/powernode/extensions/system"
mkdir -p "$EXT_ROOT"

cd "$WORKSPACE"

# --- server/ (unchanged from the pre-existing arm) --------------------
rsync -a \
  --exclude='.git' --exclude='tmp' --exclude='log' \
  --exclude='node_modules' --exclude='coverage' \
  server/ "$EXT_ROOT/server/"

if [ -f extension.json ]; then
  cp extension.json "$EXT_ROOT/extension.json"
fi

# --- config/ (IMP-fad0b3f67255 — THE FIX) ------------------------------
# System::Runbooks::Catalog::EXTENSION_ROOT (server/app/services/system/
# runbooks/catalog.rb) climbs from server/app/services/system/runbooks/
# back up to the extension repo ROOT and reads config/runbooks.yml from
# there — never from server/config/. This tree was never in the arm's
# rsync source list at all (only server/, worker/, extension.json were),
# so it silently never shipped: not an rsync failure, not a missing-file
# warning, nothing — the rsync commands above completed with exit 0 on
# every build, because none of them were ever asked to look at config/.
if [ -d config ]; then
  rsync -a \
    --exclude='.git' --exclude='tmp' \
    config/ "$EXT_ROOT/config/"
else
  echo "[stage-1.5] extension-system: FATAL — config/ tree missing from workspace; System::Runbooks::Catalog reads config/runbooks.yml from the extension root at boot, and its absence is what this fix exists to catch at BUILD time instead of as a boot-time log line." >&2
  exit 1
fi

# --- worker/ (unchanged; same FATAL-guard shape config/ above now uses) -
if [ -d worker ]; then
  rsync -a \
    --exclude='.git' --exclude='tmp' --exclude='log' \
    --exclude='node_modules' --exclude='coverage' \
    worker/ "$EXT_ROOT/worker/"
else
  echo "[stage-1.5] extension-system: FATAL — worker/ tree missing from workspace; extension.json declares components.worker:true but no worker code to ship" >&2
  exit 1
fi

# --- Fail-loud verification (IMP-fad0b3f67255) --------------------------
# Not redundant with the `[ -d config ]` guard above: that guard only
# proves the SOURCE existed before the rsync ran. This proves the file
# this whole bug is about actually landed in the DESTINATION afterward —
# the exact gap a passing rsync with the wrong source args left invisible
# the first time. A future edit that narrows the config/ rsync (an
# --exclude, a mask) to where runbooks.yml itself stops shipping again
# fails the BUILD here instead of surfacing as a boot-time log line on a
# deployed hub.
if [ ! -f "$EXT_ROOT/config/runbooks.yml" ]; then
  echo "[stage-1.5] extension-system: FATAL — config/runbooks.yml did not land in the staged tree after rsync (checked $EXT_ROOT/config/runbooks.yml). System::Status::RemediationWiring#register_runbook_source! will fail on every boot of any hub-backend that loads this build." >&2
  exit 1
fi
