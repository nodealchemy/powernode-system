#!/usr/bin/env bash
# module-forge-build.sh — THE CONTRACT between the module-forge NodeModule
# and the on-node agent's build-job handler (campaign 019f5885 inc7 Part
# B). Builds ONE module's erofs artifact natively (chroot, no Docker, no
# act_runner) inside this module's own baked buildroot (/opt/buildenv —
# see manifest.yaml's description) and pushes it, UNSIGNED, to an OCI
# registry — reproducing scripts/module-build/build-one-module.sh +
# push.sh (campaign 019f5885 inc6), the exact same stage scripts the
# Gitea CI pipeline (.gitea/workflows/build-platform-modules.yaml) runs.
#
# Job parameters come ONLY from the process environment (never CLI
# arguments) — this is a hard requirement, not a style choice: several of
# them are credentials (ORAS_REGISTRY_PASSWORD, optionally PARENT_PAT), and
# the platform's cryptographic-material-safety rule forbids passing secrets
# as CLI/function arguments (visible in `ps`, /proc/<pid>/cmdline, and
# shell history). The one CLI flag this script accepts, --result-file, is
# a plain output PATH, never a secret. set -eu is load-bearing; NEVER add
# `set -x` here — a trace would print PARENT_PAT/ORAS_REGISTRY_PASSWORD to
# whatever captures this script's stderr.
#
# ENV CONTRACT (Part B's agent handler must set these as real child-process
# environment variables — never interpolated into a shell command string;
# see the crypto-material-safety note above):
#
# Required:
#   MODULE                  module slug to build (must have
#                            modules/$MODULE/manifest.yaml at BUILD_SHA in
#                            the cloned MODULE_SOURCE_URL)
#   BUILD_SHA                 commit SHA to check out and build
#   MODULE_SOURCE_URL          git clone URL for the repo containing modules/
#                            (in practice this repo, extensions/system — kept
#                            generic on purpose). May ALREADY have a
#                            credential embedded in its userinfo (the
#                            caller's job, e.g. via Go's url.UserPassword) —
#                            this script clones it VERBATIM, exactly as
#                            given, and never rewrites/re-embeds anything
#                            into it. This is a DIFFERENT credential/repo
#                            than PARENT_PAT below (this one is for the
#                            modules/ repo itself; PARENT_PAT is for the
#                            separate parent powernode-platform repo,
#                            consulted only inside the chroot) — never
#                            conflate the two.
#   ORAS_REGISTRY_USER          oras registry username — CREDENTIAL, env-only
#   ORAS_REGISTRY_PASSWORD      oras registry password/token — CREDENTIAL,
#                            env-only
#   OCI_REF                    target TAG to publish under (NOT a full OCI
#                            reference despite the name — forwarded
#                            verbatim to push.sh's --tag; e.g. "1.4.0" or a
#                            short commit sha, exactly what push.sh's
#                            `inputs.tag` already accepts today)
#
# Optional:
#   PARENT_PAT                 PAT for cloning the parent powernode-platform
#                            repo — CREDENTIAL, env-only. Only consulted by
#                            stage15.sh's Class-B arms (powernode-hub-
#                            backend/-worker/-frontend); harmless/unused for
#                            every other MODULE. Forwarded to stage15.sh
#                            (invoked inside the chroot) by simple process-
#                            environment inheritance — see "no secrets in
#                            argv" below.
#   ORAS_REGISTRY               registry host to push to. Default:
#                            git.powernode.org. Forwarded to push.sh's new
#                            `--registry` flag (this increment's one small
#                            addition to that shared, already-landed
#                            script).
#   APT_SNAPSHOT                caller-supplied EXPECTED value of the
#                            cloned modules/$MODULE/manifest.yaml's own
#                            `build.apt_snapshot`. This is an assertion,
#                            NOT a mutator: the manifest checked out at
#                            BUILD_SHA remains the single source of truth
#                            for every build path (exactly like every other
#                            module build, native or CI) — if set and it
#                            disagrees with what's actually in the cloned
#                            manifest, this script FAILS FAST rather than
#                            silently building against a caller's stale
#                            assumption. Best-effort grep/sed extraction
#                            (no YAML parser on the host layer — see
#                            manifest.yaml's package_spec, deliberately
#                            minimal); unset skips the check entirely.
#   ARCH                        amd64|arm64. Default: amd64. Forwarded to
#                            build-one-module.sh's --arch.
#   PARENT_HOST / PARENT_PATH  forwarded to build-one-module.sh's
#                            --parent-host / --parent-path (only consulted
#                            by the same Class-B arms as PARENT_PAT).
#                            Defaults match build-one-module.sh's own
#                            (github.com /
#                            nodealchemy/powernode-platform) — PUBLIC repo.
#
# CLI:
#   --result-file FILE          also write the RESULT JSON here (a plain
#                            path, not a secret). stdout always gets it
#                            regardless, as the LAST (and only) line —
#                            every other line this script itself prints
#                            goes to stderr; the chrooted build/push
#                            commands' own (voluminous) stdout is
#                            redirected to this script's stderr too, so
#                            stdout is reserved for the result JSON alone.
#
# Output — RESULT JSON, exactly these six keys (the CONTRACT shape Part
# B's handler must parse):
#   {"oci_digest": "sha256:...", "fsverity_root": "...", "size": N,
#    "built_from_sha": "...", "core_source_sha": "...",
#    "core_source_remote": "..."}
#
# built_from_sha is the MODULE-SOURCE commit (the repo holding modules/),
# NOT core. core_source_sha / core_source_remote are the parent
# powernode-platform commit and host whose tree stage15.sh staged into a
# Class-B artifact — added by IMP-b2aebb9f4b17, because without them an
# artifact built from a stale core mirror is indistinguishable from a
# correct one at every downstream checkpoint. Values: a sha; "unknown"
# (Class-B, rev-parse failed); or "not_applicable" (module clones no
# parent). NOTE: the agent's moduleBuildResult struct
# (agent/internal/runtime/tasks/handlers/module_build.go) does NOT yet
# decode the two core_* keys — encoding/json drops unknown fields
# silently — so today they reach the --result-file and the OCI annotations
# push.sh stamps, but not System::NodeModuleVersion.artifacts. Threading
# them further needs an AGENT rebuild; tracked separately.
#
# Exit: non-zero on any failure (set -euo pipefail propagates the first
# one); cleanup (unmount + scratch removal) always runs via the EXIT trap,
# success or failure.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
# Both default to the paths the module-forge module bakes them at; overridable
# for a fork that bakes elsewhere, and for hermetic testing of this script's
# control flow (same env-override pattern as MODULE_FORGE_JOB_ROOT below).
BUILDENV_GOLDEN="${MODULE_FORGE_BUILDENV_GOLDEN:-/opt/buildenv}"
BUILD_SCRIPTS="${MODULE_FORGE_BUILD_SCRIPTS:-/opt/module-build}"

log()  { echo "[$SCRIPT_NAME] $*" >&2; }
die()  { echo "$SCRIPT_NAME: error: $*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage: MODULE=... BUILD_SHA=... MODULE_SOURCE_URL=... \
       ORAS_REGISTRY_USER=... ORAS_REGISTRY_PASSWORD=... OCI_REF=... \
       module-forge-build.sh [--result-file FILE]

Builds one module's erofs artifact natively (chroot, /opt/buildenv) and
pushes it (unsigned) to an OCI registry. ALL job parameters come from the
environment — see the file header for the full contract. Never pass
secrets as CLI arguments.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

RESULT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --result-file)
      [ $# -ge 2 ] || die "--result-file requires an argument"
      RESULT_FILE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1 (job parameters come from the environment, not CLI args — see --help)" ;;
  esac
done

# --- required env (never echoed; the three credentials below are read
# only, never printed) ---------------------------------------------------
: "${MODULE:?MODULE env var is required (module slug to build)}"
: "${BUILD_SHA:?BUILD_SHA env var is required (commit sha to build)}"
: "${MODULE_SOURCE_URL:?MODULE_SOURCE_URL env var is required (git clone URL)}"
: "${ORAS_REGISTRY_USER:?ORAS_REGISTRY_USER env var is required}"
: "${ORAS_REGISTRY_PASSWORD:?ORAS_REGISTRY_PASSWORD env var is required}"
: "${OCI_REF:?OCI_REF env var is required (target tag to publish)}"

# --- optional env ---------------------------------------------------------
PARENT_PAT="${PARENT_PAT:-}"
ORAS_REGISTRY="${ORAS_REGISTRY:-git.powernode.org}"
APT_SNAPSHOT="${APT_SNAPSHOT:-}"
ARCH="${ARCH:-amd64}"
PARENT_HOST="${PARENT_HOST:-github.com}"
PARENT_PATH="${PARENT_PATH:-nodealchemy/powernode-platform}"

require_cmd git
require_cmd jq
require_cmd rsync
require_cmd uuidgen
require_cmd mount
require_cmd chroot

[ -d "$BUILDENV_GOLDEN" ] || die "$BUILDENV_GOLDEN missing — is this instance actually running the module-forge module?"
[ -x "$BUILD_SCRIPTS/build-one-module.sh" ] || die "$BUILD_SCRIPTS/build-one-module.sh missing"
[ -x "$BUILD_SCRIPTS/push.sh" ] || die "$BUILD_SCRIPTS/push.sh missing"

JOB_ID="$(uuidgen)"
# Build scratch (the rsync'd golden buildroot copy + mmdebstrap's multi-GB fat
# rootfs) MUST land on a roomy, DISK-backed filesystem — never the pivot-boot
# overlay root (/), which on fleet nodes is a ~512M tmpfs-backed writable layer
# that mmdebstrap's very first apt-get fills to ENOSPC. Resolve the scratch base:
# an explicit MODULE_FORGE_JOB_ROOT override wins; else the platform's persistent
# data mount (/persist on pivot-booted nodes — a real ext4 partition with tens of
# GB free) when it's a DISTINCT filesystem from /; else /var/lib (correct on a
# normal host where / is itself a real disk). The stat-device compare keeps this
# module generic across boot styles instead of hardcoding one disk layout.
JOB_BASE="${MODULE_FORGE_JOB_ROOT:-}"
if [ -z "$JOB_BASE" ]; then
  if [ -d /persist ] && [ "$(stat -c %d /persist 2>/dev/null)" != "$(stat -c %d / 2>/dev/null)" ]; then
    JOB_BASE="/persist/module-forge"
  else
    JOB_BASE="/var/lib/module-forge"
  fi
fi
JOB_ROOT="$JOB_BASE/jobs/${JOB_ID}"
BUILDENV="$JOB_ROOT/buildenv"
WORKSPACE_HOST="$JOB_ROOT/workspace"
mkdir -p "$BUILDENV" "$WORKSPACE_HOST"
log "job ${JOB_ID}: module=${MODULE} sha=${BUILD_SHA} arch=${ARCH} registry=${ORAS_REGISTRY}"

# --- cleanup: unmount (reverse order) + drop the whole per-job scratch
# tree, on ANY exit path (success or failure). Never skipped. -------------
# bash >=4.4 (every target here — Ubuntu noble/Debian trixie both ship
# 5.2.x) iterates an empty array cleanly under `set -u`; no `:-` fallback
# needed on the expansions below.
declare -a MOUNTED=()
cleanup() {
  local rc=$?
  local m
  for m in "${MOUNTED[@]}"; do
    umount -l "$m" 2>/dev/null || true
  done
  rm -rf "$JOB_ROOT" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT INT TERM
# Always name the failing command on the last stderr line — the agent captures
# a bounded log_tail, so a bare `set -e` exit can otherwise leave no clue.
trap 'echo "[module-forge-build.sh] FAILED rc=$? at line $LINENO: $BASH_COMMAND" >&2' ERR

bind_mount() {
  local src="$1" dst="$2"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
  else
    # File bind-mount (e.g. /etc/resolv.conf): the target must be a regular
    # FILE, not a directory. The rsync from /opt/buildenv may have already
    # placed a file/symlink here — replace it with a fresh empty file so the
    # bind target is clean (mkdir'ing a path that's already a file fails
    # "File exists", which crashed the first live native build).
    mkdir -p "$(dirname "$dst")"
    rm -f "$dst"
    touch "$dst"
  fi
  mount --bind "$src" "$dst"
  MOUNTED=("$dst" "${MOUNTED[@]}")
}

# --- 1. clone MODULE_SOURCE_URL@BUILD_SHA on the HOST (git/ca-certificates
# are this module's own package_spec) — a full clone (not shallow): BUILD_SHA
# can be any point in history, and stage2-carve.sh's SOURCE_DATE_EPOCH
# derivation (`git log -1 --format=%ct`) needs the commit object present.
#
# MODULE_SOURCE_URL may arrive with a credential embedded in its userinfo
# (…://x-access-token:<token>@host/…) — the caller (the agent's ci.module_build
# handler) builds source_repo_url + source_token into it. A `git clone`/`fetch`
# FAILURE prints the URL to stderr, so a verbatim clone (and this script's own
# die() below) would leak that token in cleartext into the captured log_tail →
# System::Task.error_message. To make that leak impossible fleet-wide: STRIP the
# userinfo, clone the CREDENTIAL-FREE url, and hand the credential to git
# out-of-band via GIT_ASKPASS — the token then lives only in a helper's env,
# never in argv, the URL, or ANY error output. PARENT_PAT (a SEPARATE credential
# for the SEPARATE parent powernode-platform repo, cloned inside the chroot in
# step 4) is unaffected by all of this. ----------------------------------------
SOURCE_URL_SAFE="$MODULE_SOURCE_URL"
case "$MODULE_SOURCE_URL" in
  *"://"*"@"*)
    _proto="${MODULE_SOURCE_URL%%://*}"
    _rest="${MODULE_SOURCE_URL#*://}"
    _cred="${_rest%%@*}"
    _hostpath="${_rest#*@}"
    SOURCE_URL_SAFE="${_proto}://${_hostpath}"
    ASKPASS_HELPER="$JOB_ROOT/.git-askpass"   # under JOB_ROOT → wiped by cleanup trap
    printf '#!/bin/sh\ncase "$1" in Username*) printf %%s "$PN_GIT_USER";; *) printf %%s "$PN_GIT_PASS";; esac\n' > "$ASKPASS_HELPER"
    chmod 700 "$ASKPASS_HELPER"
    export GIT_ASKPASS="$ASKPASS_HELPER" GIT_TERMINAL_PROMPT=0
    export PN_GIT_USER="${_cred%%:*}"
    PN_GIT_PASS="${_cred#*:}"; [ "$PN_GIT_PASS" = "$_cred" ] && PN_GIT_PASS=""
    export PN_GIT_PASS
    unset _proto _rest _cred _hostpath
    ;;
esac
log "cloning module source at ${BUILD_SHA}…"
git clone --quiet "$SOURCE_URL_SAFE" "$WORKSPACE_HOST"
if ! git -C "$WORKSPACE_HOST" checkout --quiet "$BUILD_SHA" 2>/dev/null; then
  git -C "$WORKSPACE_HOST" fetch --quiet origin "$BUILD_SHA"
  git -C "$WORKSPACE_HOST" checkout --quiet "$BUILD_SHA"
fi

MFPATH="$WORKSPACE_HOST/modules/$MODULE/manifest.yaml"
[ -f "$MFPATH" ] || die "no modules/$MODULE/manifest.yaml at ${BUILD_SHA} in ${SOURCE_URL_SAFE}"

# --- Build scripts: prefer the ones checked out at BUILD_SHA over the baked
# /opt/module-build. The module-forge module bakes scripts/module-build/* into
# /opt/module-build at ITS OWN build time (see manifest.yaml), so a build "at
# BUILD_SHA" that runs the baked stage1/stage15/stage2/push scripts silently
# uses whatever commit the forge was last built from — NOT the requested sha —
# producing artifacts that don't reflect BUILD_SHA. The workspace we just
# cloned already carries scripts/module-build/ at BUILD_SHA, and
# build-one-module.sh resolves its sibling stage scripts relative to itself
# (SCRIPT_DIR), so re-pointing at this directory makes the WHOLE stage chain
# reflect the requested commit. Fall back to the baked copy only when the
# checkout genuinely lacks them (a sha/fork predating the script extraction).
WS_BUILD_SCRIPTS="$WORKSPACE_HOST/scripts/module-build"
if [ -x "$WS_BUILD_SCRIPTS/build-one-module.sh" ] && [ -x "$WS_BUILD_SCRIPTS/push.sh" ]; then
  BUILD_SCRIPTS="$WS_BUILD_SCRIPTS"
  log "using build scripts checked out at ${BUILD_SHA} (${WS_BUILD_SCRIPTS})"
else
  log "WARNING: no scripts/module-build/ at ${BUILD_SHA} in the checkout — falling back to baked ${BUILD_SCRIPTS}"
fi

# --- APT_SNAPSHOT: assertion, not a mutator (see file header). Best-effort
# grep/sed — this host layer deliberately carries no YAML parser (see
# manifest.yaml's package_spec); a manifest whose `build:` block doesn't
# match this narrow, already-consistent shape just skips the check with a
# warning rather than failing the whole build over a parsing edge case. ---
if [ -n "$APT_SNAPSHOT" ]; then
  ACTUAL_SNAPSHOT=$(awk '/^build:/{f=1; next} f && /^[^[:space:]]/{f=0} f' "$MFPATH" \
    | sed -n 's/^[[:space:]]*apt_snapshot:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' \
    | head -n1)
  if [ -z "$ACTUAL_SNAPSHOT" ]; then
    log "WARNING: could not extract build.apt_snapshot from $MFPATH to check against APT_SNAPSHOT=$APT_SNAPSHOT — skipping drift guard"
  elif [ "$ACTUAL_SNAPSHOT" != "$APT_SNAPSHOT" ]; then
    die "APT_SNAPSHOT=$APT_SNAPSHOT (caller-supplied) does not match modules/$MODULE/manifest.yaml's build.apt_snapshot=$ACTUAL_SNAPSHOT at ${BUILD_SHA} — refusing (drift guard; the manifest remains the single source of truth for every build path)"
  fi
fi

# --- 2. seed a fresh, per-job COPY of the golden buildroot. Never chroot
# into $BUILDENV_GOLDEN directly: several stage15.sh arms (e.g.
# powernode-hub-backend/-worker) apt-get-install packages directly onto
# whatever root they run against, which here would mean writing all over
# this module's OWN baked-into-erofs /opt/buildenv. That would very likely
# still work (this module's CAP_SYS_ADMIN grant should make ordinary
# overlayfs copy-up transparent), but it's untested by this increment's
# static-only validation — the rsync copy sidesteps the question entirely,
# and as a bonus guarantees every job starts from an uncontaminated
# buildroot regardless of what a previous job on a reused/pooled instance
# left behind. -------------------------------------------------------------
log "seeding ephemeral buildroot copy from ${BUILDENV_GOLDEN}…"
rsync -a "$BUILDENV_GOLDEN/" "$BUILDENV/"

# stage2-carve.sh's --prune-empty-dirs strips EVERY empty directory from the
# golden buildroot's carve, so /opt/buildenv ships with no /tmp, /run, /sys,
# etc. — recreate the standard skeleton the chrooted build depends on. /tmp
# is load-bearing (build-one-module.sh writes /tmp/manifest.json + the whole
# /tmp/* fat/slim/erofs stage contract; without it the chroot dies exit 2 on
# its first redirect). The apt partial dirs are mask-stripped from the carve
# and needed by Class-B stage15 arms' in-chroot apt-get.
mkdir -p "$BUILDENV/tmp" "$BUILDENV/var/tmp" "$BUILDENV/run" "$BUILDENV/sys" \
         "$BUILDENV/var/lib/apt/lists/partial" "$BUILDENV/var/cache/apt/archives/partial"
chmod 1777 "$BUILDENV/tmp" "$BUILDENV/var/tmp"

# --- 3. chroot mounts: workspace + build scripts (bind, read-only) + the
# minimum a chrooted mmdebstrap/git/curl need to function (proc, dev,
# resolv.conf for DNS). ----------------------------------------------------
mkdir -p "$BUILDENV/mnt/workspace" "$BUILDENV/opt/module-build" "$BUILDENV/proc" "$BUILDENV/dev" "$BUILDENV/etc"
bind_mount "$WORKSPACE_HOST" "$BUILDENV/mnt/workspace"
bind_mount "$BUILD_SCRIPTS" "$BUILDENV/opt/module-build"
mount -o remount,bind,ro "$BUILDENV/opt/module-build"
mount -t proc proc "$BUILDENV/proc"
MOUNTED=("$BUILDENV/proc" "${MOUNTED[@]}")
bind_mount /dev "$BUILDENV/dev"
bind_mount /etc/resolv.conf "$BUILDENV/etc/resolv.conf"

# Content-addressed build skip — ON by default from here (019ff2aa). Reverse-
# dependency expansion legitimately names modules whose own inputs did not
# change (one agent/ edit plans 22), and rebuilding those costs real minutes.
# should-skip-build.sh compares a hash of the module's DECLARED inputs against
# the org.powernode.build-inputs-sha256 annotation on the last published
# artifact, and fails SAFE to BUILD on every error path.
#
# Safe to default ON because the unsafe modules opt THEMSELVES out: the ones
# that read content outside modules/<slug>/ (the four stage15 needs_parent
# modules, powernode-system-base which builds agent/, and module-forge which
# bakes scripts/module-build/) refuse to skip unless BUILD_INPUT_PATHS declares
# their real inputs. So this enables it exactly for the package-origin modules,
# whose modules/<slug> tree IS their whole input.
#
# Overridable: set BUILD_SKIP_UNCHANGED=0 to force a rebuild of everything.
# Reaches build-one-module.sh via process-environment inheritance through the
# chroot below, the same way PARENT_PAT does.
export BUILD_SKIP_UNCHANGED="${BUILD_SKIP_UNCHANGED:-1}"
log "content-addressed skip: BUILD_SKIP_UNCHANGED=${BUILD_SKIP_UNCHANGED}"

# --- 4. run build-one-module.sh inside the chroot. HOME=/root is set
# explicitly (not inherited) so oras (invoked in the push step below)
# writes its login config under a HOME that actually exists inside this
# chroot. Non-secret CLI args only (MODULE/BUILD_SHA/ARCH/PARENT_HOST/
# PARENT_PATH); PARENT_PAT (a credential) is NOT placed on this command
# line — it reaches stage15.sh purely via process-environment inheritance,
# exactly like every other invocation of stage15.sh in this pipeline. The
# chrooted build's own (voluminous) stdout is redirected to OUR stderr —
# see the file header: this script's real stdout is reserved for the final
# RESULT JSON alone. --------------------------------------------------------
log "building ${MODULE}@${BUILD_SHA} inside ${BUILDENV} chroot…"
if ! chroot "$BUILDENV" /bin/bash -c "
  export HOME=/root
  cd /mnt/workspace
  bash /opt/module-build/build-one-module.sh \
    --module '$MODULE' --sha '$BUILD_SHA' --workspace /mnt/workspace \
    --arch '$ARCH' --parent-host '$PARENT_HOST' --parent-path '$PARENT_PATH'
" >&2; then
  die "build-one-module.sh failed inside chroot for ${MODULE}@${BUILD_SHA}"
fi

[ -s "$BUILDENV/tmp/$MODULE.erofs" ] || die "build-one-module.sh reported success but /tmp/$MODULE.erofs is missing/empty inside the chroot"

# --- 5. push (UNSIGNED — no cosign; signing moves server-side in inc8) +
# resolve the pushed digest, in the SAME chroot invocation (oras's login
# config from push.sh's `oras login` needs to still be present for the
# resolve that follows it). ORAS_REGISTRY_USERNAME is push.sh's own env-var
# name (this contract's ORAS_REGISTRY_USER is translated here) — both stay
# out of the command line, inherited via process environment exactly like
# PARENT_PAT above. ---------------------------------------------------------
log "pushing ${MODULE}:${OCI_REF} to ${ORAS_REGISTRY} (unsigned)…"
export ORAS_REGISTRY_USERNAME="$ORAS_REGISTRY_USER"
export ORAS_REGISTRY_PASSWORD
PUSH_OUT="$BUILDENV/tmp/module-forge-push-output.env"
if ! chroot "$BUILDENV" /bin/bash -c "
  export HOME=/root
  cd /mnt/workspace
  bash /opt/module-build/push.sh \
    --module '$MODULE' --sha '$BUILD_SHA' --workspace /mnt/workspace \
    --tag '$OCI_REF' --registry '$ORAS_REGISTRY' \
    --output-file /tmp/module-forge-push-output.env
" >&2; then
  die "push.sh failed for ${MODULE}@${BUILD_SHA}"
fi
unset ORAS_REGISTRY_USERNAME ORAS_REGISTRY_PASSWORD

[ -s "$PUSH_OUT" ] || die "push.sh reported success but wrote no output at $PUSH_OUT"
EROFS_REF=$(sed -n 's/^erofs_ref=//p' "$PUSH_OUT" | head -n1)
[ -n "$EROFS_REF" ] || die "push.sh output at $PUSH_OUT has no erofs_ref= line"

# oras manifest fetch --descriptor (stable) rather than `oras resolve`
# (marked [Experimental] upstream as of oras 1.2) — same digest, a command
# this pipeline can rely on staying put.
log "resolving pushed digest for ${EROFS_REF}…"
OCI_DIGEST=$(chroot "$BUILDENV" /bin/bash -c "
  export HOME=/root
  oras manifest fetch --descriptor '$EROFS_REF'
" 2>/dev/null | jq -r '.digest')
if [ -z "$OCI_DIGEST" ] || [ "$OCI_DIGEST" = "null" ]; then
  die "could not resolve oci_digest for $EROFS_REF"
fi

# --- 6. assemble the RESULT JSON (the four-key CONTRACT shape — see file
# header). fsverity_root/size come straight from Stage 2's own
# .erofs.meta, read directly off the chroot's filesystem (no copy needed —
# chroot shares the underlying storage with the host, it's a root-view
# change, not a separate mount namespace). -----------------------------------
META_FILE="$BUILDENV/tmp/$MODULE.erofs.meta"
[ -s "$META_FILE" ] || die "$META_FILE missing — Stage 2 (stage2-carve.sh) did not produce it"
FSVERITY_ROOT=$(sed -n 's/^fsverity_root=//p' "$META_FILE" | head -n1)
SIZE=$(sed -n 's/^size=//p' "$META_FILE" | head -n1)
[ -n "$FSVERITY_ROOT" ] || die "$META_FILE has no fsverity_root= line"
[ -n "$SIZE" ] || die "$META_FILE has no size= line"

# --- BEGIN core-source provenance read ---
# Core-tree provenance (IMP-b2aebb9f4b17). Read stage15.sh's capture off the
# chroot's filesystem exactly the way fsverity_root/size are read above — the
# chroot shares the host's storage, so no copy is needed.
#
# built_from_sha below is the MODULE-SOURCE commit and is silent about core, so
# for a Class-B module it cannot distinguish an artifact carrying a stale core
# mirror from a correct one. These two fields are that missing answer, and they
# are deliberately NAMED for core rather than anything that could be mistaken
# for the module source.
#
# THREE DISTINGUISHABLE STATES — an absent field must never be indistinguishable
# from a successful one:
#   <sha>            a Class-B build; the core commit its tree came from
#   "unknown"        a Class-B build whose rev-parse failed (stage15.sh's own
#                    fallback) — core-derived content, unattributable
#   "not_applicable" this module clones no parent at all (not Class-B)
#
# Explicit `if` blocks, not `[ -n "$x" ] && y=...`: under this script's `set -e`
# a trailing false test would abort the whole build.
PARENT_PROV_FILE="$BUILDENV/tmp/parent-provenance.env"
CORE_SOURCE_SHA="not_applicable"
CORE_SOURCE_REMOTE="not_applicable"
if [ -s "$PARENT_PROV_FILE" ]; then
  _prov_sha=$(sed -n 's/^core_source_sha=//p' "$PARENT_PROV_FILE" | head -n1)
  _prov_remote=$(sed -n 's/^core_source_remote=//p' "$PARENT_PROV_FILE" | head -n1)
  if [ -n "$_prov_sha" ]; then CORE_SOURCE_SHA="$_prov_sha"; fi
  if [ -n "$_prov_remote" ]; then CORE_SOURCE_REMOTE="$_prov_remote"; fi
  unset _prov_sha _prov_remote
fi
log "core provenance: sha=${CORE_SOURCE_SHA} remote=${CORE_SOURCE_REMOTE}"
# --- END core-source provenance read ---

RESULT_JSON=$(jq -nc \
  --arg digest "$OCI_DIGEST" \
  --arg root "$FSVERITY_ROOT" \
  --argjson size "$SIZE" \
  --arg sha "$BUILD_SHA" \
  --arg core_sha "$CORE_SOURCE_SHA" \
  --arg core_remote "$CORE_SOURCE_REMOTE" \
  '{oci_digest: $digest, fsverity_root: $root, size: $size, built_from_sha: $sha,
    core_source_sha: $core_sha, core_source_remote: $core_remote}')

if [ -n "$RESULT_FILE" ]; then
  printf '%s\n' "$RESULT_JSON" > "$RESULT_FILE"
fi
log "done: ${MODULE}@${BUILD_SHA} -> ${EROFS_REF} (${OCI_DIGEST})"
# The ONLY line this script ever prints to real stdout — see file header.
printf '%s\n' "$RESULT_JSON"
