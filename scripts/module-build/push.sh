#!/usr/bin/env bash
# push.sh — oras login/push (+ OCI annotations) for the platform module
# build pipeline. Deliberately does NOT sign — cosign signing stays an
# inline step in the workflow for now (a later increment moves signing
# server-side; see the workflow's "Cosign sign" step).
#
# Extracted VERBATIM (campaign 019f5885 inc6 — pure refactor, no logic
# changes) from the oras-login/push/tag portion of the "Cosign sign + oras
# push" step of .gitea/workflows/build-platform-modules.yaml: same
# commands, same order, same env semantics — so the pushed OCI artifact +
# its annotations are byte-identical to the pre-refactor inline step. The
# workflow step is now a thin invocation of this script followed by a
# separate (still-inline) "Cosign sign" step; a future on-node/native build
# (inc7+, driven by build-one-module.sh in this same directory) can invoke
# this script directly with no Gitea Actions context at all (signing moves
# server-side in that same future increment).
#
# Values threaded through as explicit CLI args below (never read from the
# process environment by this script, except the two credentials noted):
#   $MODULE          — was GITHUB_ENV-set by "Resolve build slot"
#                      (untouched); now --module.
#   $GITHUB_SHA        — was read directly by the inline step (the
#                      built_from_sha annotation); now --sha, populated
#                      into a same-named $GITHUB_SHA variable so the body
#                      needed no further text change.
#   inputs.tag          — was a literal `${{ inputs.tag }}` Actions
#                      expression substituted into the shell text at
#                      workflow-render time (not a shell variable at all);
#                      now --tag (may be empty, exactly like the original
#                      unset-input case — the `git rev-parse --short HEAD`
#                      fallback below is unchanged).
#   $GITHUB_OUTPUT       — was appended to directly by the inline step to
#                      publish `erofs_ref`/`tag` as step outputs; now
#                      optional --output-file (the workflow step passes
#                      `--output-file "$GITHUB_OUTPUT"` to reproduce that
#                      exact behavior; a native caller omits it and reads
#                      the same two lines from stdout instead).
# NOT threaded as CLI args — deliberately read from the process
# environment only, per the platform's cryptographic material safety rule
# (secrets must never be passed as function/CLI arguments visible in `ps`,
# shell history, or CI step logs). Both were, and remain, the calling
# step's `env:` block:
#   $ORAS_REGISTRY_USERNAME, $ORAS_REGISTRY_PASSWORD
# $WORKSPACE (required arg) replaces the implicit $GITHUB_WORKSPACE cwd
# Gitea Actions gives every `run:` step — needed here for the `git
# rev-parse --short HEAD` tag fallback and the relative
# `scripts/ci-compute-dirty-closure.sh` invocation.
# /tmp/$MODULE.erofs, /tmp/$MODULE.erofs.meta, /tmp/$MODULE.packages.txt
# are the SAME hardcoded literals the inline step used (Stage 1/2's
# outputs) — not parameterized, matching the rest of this script family.
#
# Usage:
#   push.sh --module MODULE --sha SHA --workspace DIR
#           [--tag TAG] [--registry HOST] [--output-file FILE]
#
# Required:
#   --module MODULE        module slug
#   --sha SHA                commit SHA being built (was $GITHUB_SHA) —
#                           used for the org.powernode.built_from_sha
#                           annotation
#   --workspace DIR           checked-out repo root (was the implicit
#                           $GITHUB_WORKSPACE cwd)
#
# Optional:
#   --tag TAG                  version tag for the published artifact (was
#                           `${{ inputs.tag }}`); empty/omitted falls back
#                           to `git rev-parse --short HEAD` in --workspace,
#                           exactly as the inline step did
#   --registry HOST             registry host to push to. Default:
#                           git.powernode.org (unchanged from before this
#                           flag existed — the workflow's own invocation
#                           doesn't pass it). Added in campaign 019f5885
#                           inc7 (Part A) so the module-forge NodeModule's
#                           entrypoint (module-forge-build.sh) can honor
#                           its own ORAS_REGISTRY env var without
#                           duplicating this script's oras-login/push/tag
#                           logic a second time — a small, backward-
#                           compatible addition, not a behavior change for
#                           any existing caller.
#   --output-file FILE         append `erofs_ref=...` / `tag=...` lines
#                           here (pass "$GITHUB_OUTPUT" from the workflow
#                           step to reproduce the original step-output
#                           behavior); when omitted, the same two lines
#                           print to stdout instead
#
# Env (required, credentials — see the safety note above):
#   ORAS_REGISTRY_USERNAME, ORAS_REGISTRY_PASSWORD
#
# Reads:  /tmp/$MODULE.erofs, /tmp/$MODULE.erofs.meta,
#         /tmp/$MODULE.packages.txt (Stage 1/2 outputs)
# Writes: pushes $REGISTRY_HOST/powernode/$MODULE:$TAG (+ :latest tag) —
#         REGISTRY_HOST defaults to git.powernode.org, override via --registry
#
# Exit: non-zero on any oras/git/hash failure (set -euo pipefail
# propagates the first one).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: push.sh --module MODULE --sha SHA --workspace DIR
               [--tag TAG] [--registry HOST] [--output-file FILE]

oras login/push (+ OCI annotations) for one module's erofs artifact. Does
NOT sign (cosign stays an inline workflow step for now). Requires
ORAS_REGISTRY_USERNAME / ORAS_REGISTRY_PASSWORD in the environment — never
pass credentials as CLI arguments. See the file header for the full option
reference and the workflow-env-var mapping.
EOF
}

die() {
  echo "push.sh: error: $*" >&2
  exit 2
}

MODULE=""
GITHUB_SHA=""
WORKSPACE=""
INPUT_TAG=""
REGISTRY_HOST="git.powernode.org"
OUTPUT_FILE=""
# Credentials — read only from the process environment (see file header),
# never as CLI flags. The `:-` defaults keep this safe under `set -u`; a
# genuinely missing credential still fails loudly at `oras login` below,
# same failure mode as the original inline step.
ORAS_REGISTRY_USERNAME="${ORAS_REGISTRY_USERNAME:-}"
ORAS_REGISTRY_PASSWORD="${ORAS_REGISTRY_PASSWORD:-}"

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
    --tag)
      [ $# -ge 2 ] || die "--tag requires an argument"
      INPUT_TAG="$2"; shift 2 ;;
    --registry)
      [ $# -ge 2 ] || die "--registry requires an argument"
      REGISTRY_HOST="$2"; shift 2 ;;
    --output-file)
      [ $# -ge 2 ] || die "--output-file requires an argument"
      OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[ -n "$MODULE" ] || { usage >&2; die "--module is required"; }
[ -n "$GITHUB_SHA" ] || { usage >&2; die "--sha is required"; }
[ -n "$WORKSPACE" ] || { usage >&2; die "--workspace is required"; }

# Addition (not in the original inline step): the inline step relied on
# Gitea Actions' implicit run-step cwd ($GITHUB_WORKSPACE) for both the
# `git rev-parse --short HEAD` tag fallback and the relative
# `scripts/ci-compute-dirty-closure.sh` invocation below. This script has
# no such implicit context.
cd "$WORKSPACE"

# ---------------------------------------------------------------------------
# Everything below (through `oras tag ... latest`) is VERBATIM from the
# workflow's push step body, up to the point where the original inlined
# `cosign sign` — that line, and the vector of secrets it needs
# (COSIGN_PRIVATE_KEY/COSIGN_PASSWORD), are deliberately NOT here; the
# workflow runs cosign as its own step immediately after this script. The
# `TAG=` line is the one substitution: the original had the literal Actions
# expression `${{ inputs.tag }}` inline; here it's `$INPUT_TAG` from the
# arg parsing above. The final two `echo ... >> "$GITHUB_OUTPUT"` lines are
# replaced by the output-emission block at the bottom (optional
# --output-file, else stdout) — see the file header for why. The
# `git.powernode.org` literal below is now `$REGISTRY_HOST` (campaign
# 019f5885 inc7 Part A addition — see the file header's --registry note);
# its default is the exact same literal, so every existing caller
# (unchanged, no --registry passed) gets byte-identical behavior.
# ---------------------------------------------------------------------------

# Tag = workflow input, else commit SHA short.
TAG="$INPUT_TAG"
if [ -z "$TAG" ]; then TAG=$(git rev-parse --short HEAD); fi
REGISTRY_NS="${REGISTRY_HOST}/powernode"
EROFS_REF="${REGISTRY_NS}/$MODULE:${TAG}"
# shellcheck disable=SC2034  # pre-existing in the original inline step —
# `oras tag "$EROFS_REF" latest` below uses the literal string "latest",
# not this variable; left as-is (not "fixed") to keep this extraction
# byte-for-byte verbatim.
LATEST_REF="${REGISTRY_NS}/$MODULE:latest"

# `oras` reads credentials from ~/.docker/config.json or
# via explicit `oras login` — it does NOT pick up
# ORAS_REGISTRY_USERNAME / PASSWORD env vars on its own.
# Authenticate first so the subsequent `oras push` against
# the private Gitea registry doesn't 401.
oras login "$REGISTRY_HOST" \
  --username "$ORAS_REGISTRY_USERNAME" \
  --password-stdin <<< "$ORAS_REGISTRY_PASSWORD"

# Compute apt-closure-sha256 for this module so it lands on
# the OCI artifact's annotations. The dirty-closure script's
# drift-check mode reads this annotation on the next run to
# decide whether to rebuild this module when its source
# didn't change. APT_PROBE_MODE=local because the runner IS
# debian:trixie-slim — running apt-cache here gives exactly
# the versions Stage 1's mmdebstrap would see.
APT_HASH=$(APT_PROBE_MODE=local \
  bash scripts/ci-compute-dirty-closure.sh \
    apt-hash "$MODULE" 2>/dev/null || true)
echo "[push] apt-closure-sha256 for $MODULE: ${APT_HASH:-<empty>}"

# SBOM stepping stone (campaign 019f5885 inc5): sha256 of the
# resolved package list Stage 1 captured, so a consumer can
# detect "package set changed" from the annotation alone
# without pulling+diffing the packages layer. Full SLSA
# provenance remains queued (019f3112-f719-7152-aeac-51a3e833259f).
PACKAGES_HASH=$(sha256sum "/tmp/$MODULE.packages.txt" | awk '{print $1}')
echo "[push] resolved-packages sha256 for $MODULE: $PACKAGES_HASH"

# Content-addressed build skip (019ff2aa): a hash of this module's DECLARED
# build inputs, so the next run can answer "would this rebuild ship the same
# files?" without comparing artifact digests — which can never match, because
# stage2-carve stamps the build sha into SOURCE_DATE_EPOCH and the erofs UUID.
# BUILD_INPUT_PATHS is a space-separated list of extra input paths for modules
# whose stage15 arm packages a parent-repo subtree; unset is correct for a
# package-origin module, whose modules/<slug> tree is its whole input.
# Best-effort: an empty hash simply omits the annotation, and a missing
# annotation reads as "cannot skip" downstream, never as "skip".
PUSH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_INPUTS_ARGS=(--module "$MODULE")
for _p in ${BUILD_INPUT_PATHS:-}; do BUILD_INPUTS_ARGS+=(--input-path "$_p"); done
BUILD_INPUTS_HASH=$(bash "$PUSH_SCRIPT_DIR/compute-build-inputs-hash.sh" \
  "${BUILD_INPUTS_ARGS[@]}" 2>/dev/null || true)
echo "[push] build-inputs sha256 for $MODULE: ${BUILD_INPUTS_HASH:-<empty>}"

# oras complains about absolute paths in source operands.
# Run from /tmp so the file operands are bare names; the
# registry sees them with the same shape it always has
# (the colon-suffix is the mediaType annotation).
cd /tmp
ORAS_PUSH_ARGS=(
  "$EROFS_REF"
  --artifact-type application/vnd.powernode.module.v1
  "$MODULE.erofs:application/vnd.powernode.erofs"
  "$MODULE.erofs.meta:application/vnd.powernode.module.meta"
  "$MODULE.packages.txt:application/vnd.powernode.module.packages"
)
if [[ -n "$APT_HASH" ]]; then
  ORAS_PUSH_ARGS+=(--annotation "org.powernode.apt-closure-sha256=$APT_HASH")
fi
ORAS_PUSH_ARGS+=(--annotation "org.powernode.packages-sha256=$PACKAGES_HASH")
if [[ -n "$BUILD_INPUTS_HASH" ]]; then
  ORAS_PUSH_ARGS+=(--annotation "org.powernode.build-inputs-sha256=$BUILD_INPUTS_HASH")
fi
# Verifiable built-from-SHA provenance (operator amendment
# 2026-07-05): every module in this matrix — powernode-system-base
# in particular, since its ENTIRE payload is the cross-compiled Go
# agent binary (Stage 1.5 above) — is assembled from this exact
# checked-out commit. Annotating it lets anyone with oras/cosign
# inspect the pushed artifact and independently verify which
# commit's agent/ tree produced the binary inside it, without
# needing a hosted attestation document. This is deliberately a
# lightweight, directly-verifiable annotation, NOT a full SLSA
# provenance attestation (io.powernode.provenance_uri) — that
# remains queued as 019f3112-f719-7152-aeac-51a3e833259f.
ORAS_PUSH_ARGS+=(--annotation "org.powernode.built_from_sha=${GITHUB_SHA}")

# --- BEGIN core-source provenance annotations ---
# Stamp the CORE (parent powernode-platform) commit whose tree was assembled
# into this artifact, alongside built_from_sha above — which is the MODULE-SOURCE
# commit and says nothing about core (IMP-b2aebb9f4b17).
#
# This is the channel that makes core drift visible WITHOUT a shell on the
# builder: `oras manifest fetch` on the published artifact answers "which core
# commit is inside this erofs, and which host did it come from?" directly and
# permanently, for anyone, long after the builder's scratch tree is gone. The
# remote is carried too — the incident this fixes was a right-branch-name on a
# stale MIRROR, where the sha alone looked entirely plausible.
#
# Written by stage15.sh's Class-B parent-clone arm. ABSENT for every module that
# clones no parent, and absent is the correct distinct answer there ("this module
# has no core content") — not to be confused with the value `unknown`, which
# means "it has core content and the sha could not be resolved".
if [[ -f /tmp/parent-provenance.env ]]; then
  CORE_SOURCE_SHA=$(sed -n 's/^core_source_sha=//p' /tmp/parent-provenance.env | head -n1)
  CORE_SOURCE_REMOTE=$(sed -n 's/^core_source_remote=//p' /tmp/parent-provenance.env | head -n1)
  if [[ -n "$CORE_SOURCE_SHA" ]]; then
    ORAS_PUSH_ARGS+=(--annotation "org.powernode.core_source_sha=${CORE_SOURCE_SHA}")
  fi
  if [[ -n "$CORE_SOURCE_REMOTE" ]]; then
    ORAS_PUSH_ARGS+=(--annotation "org.powernode.core_source_remote=${CORE_SOURCE_REMOTE}")
  fi
fi
# --- END core-source provenance annotations ---

oras push "${ORAS_PUSH_ARGS[@]}"

# Also tag this build as `:latest` so the drift-check's
# canonical fetch (powernode/<mod>:latest) always points
# at the newest annotation. Use `oras tag` to alias without
# re-uploading layers.
oras tag "$EROFS_REF" latest
cd - >/dev/null

# ---------------------------------------------------------------------------
# Output emission — replaces the original's `echo ... >> "$GITHUB_OUTPUT"`.
# LATEST_REF is computed above (verbatim) but, as in the original inline
# step, never read again after the `oras tag ... latest` call (a
# pre-existing latent unused-value; not introduced here).
# ---------------------------------------------------------------------------
if [ -n "$OUTPUT_FILE" ]; then
  {
    echo "erofs_ref=$EROFS_REF"
    echo "tag=$TAG"
  } >> "$OUTPUT_FILE"
else
  echo "erofs_ref=$EROFS_REF"
  echo "tag=$TAG"
fi
