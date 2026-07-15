#!/usr/bin/env bash
# module-forge-package-build.sh — THE CONTRACT between the module-forge
# NodeModule and the on-node agent's ci.package_build task handler
# (campaign 019f6084 inc-D). Sibling of module-forge-build.sh (which builds
# a manifest-driven platform module from a git checkout); this script
# instead builds a MATERIALIZED PACKAGE module — one apt/rpm package plus
# whatever apt pulls in transitively — straight from a package recipe that
# travels entirely in the environment, since there is no modules/<slug>
# tree / manifest.yaml to check out for an auto-generated package module
# (see System::PackageClosureBuildBridge's class doc).
#
# Reuses module-forge-build.sh's chroot skeleton VERBATIM (same JOB_ROOT
# resolution, same per-job /opt/buildenv copy, same cleanup trap) because
# this module's OWN host-side package_spec is deliberately minimal (git,
# rsync, jq, ca-certificates, uuid-runtime — see manifest.yaml) — mmdebstrap,
# erofs-utils, fsverity, and oras all live ONLY inside /opt/buildenv (the
# nested debian:trixie buildroot baked by this module's Stage 1.5 arm), so
# every privileged step below (bootstrap, carve, mkfs.erofs, push) has to
# run inside that same chroot, exactly like the platform-module path does.
# Also reuses scripts/module-build/push.sh — the SAME push step
# module-forge-build.sh's step 5 invokes — so a package build and a
# platform module build publish through the IDENTICAL oras-login/push/tag
# path; this script does not reimplement any part of it.
#
# Job parameters come ONLY from the process environment (never CLI
# arguments) — same hard requirement as module-forge-build.sh (see that
# script's header): several of these are credentials
# (ORAS_REGISTRY_PASSWORD), and the platform's cryptographic-material-
# safety rule forbids passing secrets as CLI/function arguments visible in
# `ps`, /proc/<pid>/cmdline, or shell history. GPG_KEY_ARMOR is a PUBLIC
# signing key (not a secret in the confidentiality sense) but travels via
# env too, for the same "one contract, one style" reason module-forge-
# build.sh keeps APT_SNAPSHOT/ARCH env-only despite not being secrets
# either. set -eu is load-bearing; NEVER add `set -x` here.
#
# ENV CONTRACT (the agent's PackageBuildHandler sets these as real
# child-process environment variables — never interpolated into a shell
# command string):
#
# Required:
#   MODULE                    NodeModule slug this build is for (used for
#                              job naming, the RESULT JSON, and every
#                              /tmp/$MODULE.* scratch path push.sh expects)
#   SHA                        opaque repo-sync snapshot token
#                              (ModuleBuildBatch#head_sha for a "package"
#                              trigger batch — see PackageClosureBuildBridge
#                              — NOT a git commit; carried straight into the
#                              RESULT JSON's built_from_sha for provenance
#                              parity with the platform-module contract)
#   OCI_REF                    target TAG to publish under (forwarded
#                              verbatim to push.sh's --tag)
#   PACKAGE_NAME                one or more package names (comma or
#                              whitespace separated) to resolve via apt —
#                              this module's OWN closure member, not the
#                              whole materialized set (each member of a
#                              package closure gets its own ci.package_build
#                              task — see NativeModuleBuildOrchestrator)
#   ARCHITECTURE                target arch (amd64|arm64) — informational
#                              today (mmdebstrap builds for the host arch);
#                              multi-arch package builds are a documented
#                              follow-up (campaign 019f6084 item J)
#   REPO_KIND                    "apt" (the only kind this script currently
#                              implements — see PARKED note below)
#   REPO_URL                    apt repository base_url (PackageRepository
#                              carries no separate auth fields — this URL is
#                              cloned/fetched VERBATIM, no credential to
#                              embed)
#   ORAS_REGISTRY_USER / ORAS_REGISTRY_PASSWORD   oras registry
#                              credentials — CREDENTIAL, env-only
#
# Required when REPO_KIND=apt:
#   APT_SUITE, APT_COMPONENTS   apt repo coordinates (mmdebstrap's suite +
#                              --components)
#
# Optional:
#   ORAS_REGISTRY                registry host. Default: git.powernode.org
#                              (mirrors module-forge-build.sh)
#   PACKAGE_VERSION                exact EVR (epoch:version-release) to pin
#                              PACKAGE_NAME to (campaign 019f6084 item L —
#                              System::PackageClosureBuildBridge#package_lock,
#                              sourced from PackageModuleLink#package_version
#                              at materialize time). Only applied when
#                              PACKAGE_NAME names EXACTLY ONE package — this
#                              single env var has no way to carry more than
#                              one EVR, so a comma-separated PACKAGE_NAME
#                              logs a WARNING and builds unpinned (PARKED,
#                              see below). When applied: mmdebstrap is asked
#                              to install "$PACKAGE_NAME=$PACKAGE_VERSION"
#                              (apt fails the resolve outright if that exact
#                              version isn't available from REPO_URL at
#                              APT_SUITE/APT_COMPONENTS), and the dpkg-query
#                              step below additionally verifies the
#                              INSTALLED version matches byte-for-byte,
#                              dying with a clear error on any mismatch —
#                              the reproducibility guarantee this pin
#                              exists for. Absent: PACKAGE_NAME resolves
#                              unpinned exactly as before this lockfile
#                              existed (backward-compatible default).
#   APT_SNAPSHOT                  informational/log-only provenance value
#                              (PackageRepository#last_synced_at at
#                              dispatch time) — NOT used to rewrite
#                              REPO_URL (REPO_URL is already the resolved
#                              mirror the platform wants built from); best-
#                              effort parsed as a determinism anchor for the
#                              erofs SOURCE_DATE_EPOCH (see Stage "erofs"
#                              below) — unparseable/absent falls back to
#                              epoch 0, same "residual nondeterminism,
#                              documented rather than silently accepted"
#                              posture push.sh's vector/gcsfuse waiver note
#                              already uses elsewhere in this pipeline.
#   GPG_KEY_ARMOR                  apt repo's ASCII-armored public signing
#                              key (PackageRepository#signing_key_armor).
#                              Dearmored into a keyring and passed to
#                              mmdebstrap's --keyring. Absent: mmdebstrap
#                              runs with no --keyring override (its own
#                              default trust store) and this script emits a
#                              WARNING — real-execution behavior only a live
#                              builder can confirm (PARKED, see below).
#   MASK                          newline-separated glob excludes
#                              (NodeModule#mask_text) applied to the carve —
#                              same "- <glob>" rsync-filter technique
#                              stage2-carve.sh / derive-file-spec.sh use.
#   BATCH_ID                      ModuleBuildBatch id — log correlation
#                              only (the platform correlates the owning
#                              batch via the Task row's own
#                              options["batch_id"], set server-side before
#                              this script ever runs — see
#                              NativeModuleBuildOrchestrator#build_task_options).
#   FILE_SPEC_SOURCE                informational, log-only.
#
# PARKED (documented here, not attempted): REPO_KIND values other than
# "apt" (rpm/dnf) — this repo has no dnf/rpm bootstrap precedent anywhere
# in scripts/module-build/ (every existing stage script is mmdebstrap/apt-
# only), so inventing one here would be untested guesswork. The agent's
# PackageBuildHandler rejects non-apt recipes BEFORE ever invoking this
# script (clean failure, not a partial/silent build) — see
# agent/internal/runtime/tasks/handlers/package_build.go.
#
# ALSO PARKED: pinning more than one EVR when PACKAGE_NAME names multiple
# packages. PACKAGE_VERSION is a single scalar (the platform's lockfile is
# keyed by NodeModule, and today's closure member is always one package —
# see PackageClosureBuildBridge's class doc); a future multi-package
# PACKAGE_NAME would need a structured PACKAGE_VERSION (e.g. a
# "pkg=evr,pkg=evr" list) to pin each independently. Until then a
# multi-package PACKAGE_NAME builds unpinned, loudly (WARNING), never
# silently applying one EVR to every listed package.
#
# Output — RESULT JSON, the platform-module four-key contract PLUS
# file_spec (the one extra key a package build's result needs — see
# System::NativeModuleBuildOrchestrator#apply_package_file_spec! /
# System::PackageBuildWebhookService.apply_file_spec!):
#   {"oci_digest": "sha256:...", "fsverity_root": "...", "size": N,
#    "built_from_sha": "...", "file_spec": ["/usr/bin/foo", ...]}
# file_spec is the FULL dpkg -L owned-file list (unmasked) — MASK trims
# what actually ships in the erofs blob, exactly like every other module's
# mask trims its file_spec at consumption time; file_spec itself always
# records everything the package(s) own, per PackageBuildWebhookService's
# own doc ("Updated NodeModule.file_spec ... from dpkg -L ... output").
#
# Exit: non-zero on any failure (set -euo pipefail propagates the first
# one); cleanup (unmount + scratch removal) always runs via the EXIT trap.
#
# NOT LIVE-VALIDATED (PARKED — no leasable module-forge builder has ever
# run a build in this dev env; see campaign 019f6084 inc0's size-ledger
# finding, same posture PackageClosureBuildBridge's class doc already
# documents for the batch-dispatch side of this same pipeline). Static
# review only.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
BUILDENV_GOLDEN="/opt/buildenv"
BUILD_SCRIPTS="/opt/module-build"

log()  { echo "[$SCRIPT_NAME] $*" >&2; }
die()  { echo "$SCRIPT_NAME: error: $*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage: MODULE=... SHA=... OCI_REF=... PACKAGE_NAME=... ARCHITECTURE=... \
       REPO_KIND=apt REPO_URL=... APT_SUITE=... APT_COMPONENTS=... \
       ORAS_REGISTRY_USER=... ORAS_REGISTRY_PASSWORD=... \
       module-forge-package-build.sh [--result-file FILE]

Bootstraps ONE materialized package (+ its apt-resolved closure) into a
rootfs, derives its owned file list, carves + builds an erofs artifact,
and pushes it (unsigned) to an OCI registry — the ci.package_build analog
of module-forge-build.sh. ALL job parameters come from the environment.
Never pass secrets as CLI arguments.
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

# --- required env (credentials never echoed) ------------------------------
: "${MODULE:?MODULE env var is required}"
: "${SHA:?SHA env var is required (opaque repo-sync snapshot token)}"
: "${OCI_REF:?OCI_REF env var is required (target tag to publish)}"
: "${PACKAGE_NAME:?PACKAGE_NAME env var is required}"
: "${ARCHITECTURE:?ARCHITECTURE env var is required}"
: "${REPO_KIND:?REPO_KIND env var is required}"
: "${REPO_URL:?REPO_URL env var is required}"
: "${ORAS_REGISTRY_USER:?ORAS_REGISTRY_USER env var is required}"
: "${ORAS_REGISTRY_PASSWORD:?ORAS_REGISTRY_PASSWORD env var is required}"

[ "$REPO_KIND" = "apt" ] || die "REPO_KIND=$REPO_KIND not supported by this script (only apt) — PARKED, see file header"

APT_SUITE="${APT_SUITE:?APT_SUITE env var is required when REPO_KIND=apt}"
APT_COMPONENTS="${APT_COMPONENTS:?APT_COMPONENTS env var is required when REPO_KIND=apt}"

# --- optional env ----------------------------------------------------------
ORAS_REGISTRY="${ORAS_REGISTRY:-git.powernode.org}"
APT_SNAPSHOT="${APT_SNAPSHOT:-}"
GPG_KEY_ARMOR="${GPG_KEY_ARMOR:-}"
MASK="${MASK:-}"
BATCH_ID="${BATCH_ID:-}"
PACKAGE_VERSION="${PACKAGE_VERSION:-}"

require_cmd rsync
require_cmd uuidgen
require_cmd mount
require_cmd chroot
require_cmd jq

[ -d "$BUILDENV_GOLDEN" ] || die "$BUILDENV_GOLDEN missing — is this instance actually running the module-forge module?"
[ -x "$BUILD_SCRIPTS/push.sh" ] || die "$BUILD_SCRIPTS/push.sh missing"

JOB_ID="$(uuidgen)"
# Same disk-safety resolution as module-forge-build.sh — mmdebstrap's fat
# rootfs must land on real disk, never the pivot-boot tmpfs overlay root.
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
log "job ${JOB_ID}: module=${MODULE} package=${PACKAGE_NAME} version=${PACKAGE_VERSION:-<unpinned>} arch=${ARCHITECTURE} batch=${BATCH_ID:-<none>} registry=${ORAS_REGISTRY}"

# --- cleanup (mirrors module-forge-build.sh exactly) -----------------------
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
trap 'echo "[module-forge-package-build.sh] FAILED rc=$? at line $LINENO: $BASH_COMMAND" >&2' ERR

bind_mount() {
  local src="$1" dst="$2"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
  else
    mkdir -p "$(dirname "$dst")"
    rm -f "$dst"
    touch "$dst"
  fi
  mount --bind "$src" "$dst"
  MOUNTED=("$dst" "${MOUNTED[@]}")
}

# --- 1. seed a fresh per-job copy of the golden buildroot (mmdebstrap,
# erofs-utils, fsverity, oras, gnupg all live here — never chroot into
# BUILDENV_GOLDEN directly, same rationale as module-forge-build.sh). -------
log "seeding ephemeral buildroot copy from ${BUILDENV_GOLDEN}…"
rsync -a "$BUILDENV_GOLDEN/" "$BUILDENV/"
mkdir -p "$BUILDENV/tmp" "$BUILDENV/var/tmp" "$BUILDENV/run" "$BUILDENV/sys" \
         "$BUILDENV/var/lib/apt/lists/partial" "$BUILDENV/var/cache/apt/archives/partial"
chmod 1777 "$BUILDENV/tmp" "$BUILDENV/var/tmp"

mkdir -p "$BUILDENV/opt/module-build" "$BUILDENV/proc" "$BUILDENV/dev" "$BUILDENV/etc" "$BUILDENV/mnt/workspace"
bind_mount "$BUILD_SCRIPTS" "$BUILDENV/opt/module-build"
mount -o remount,bind,ro "$BUILDENV/opt/module-build"
mount -t proc proc "$BUILDENV/proc"
MOUNTED=("$BUILDENV/proc" "${MOUNTED[@]}")
bind_mount /dev "$BUILDENV/dev"
bind_mount /etc/resolv.conf "$BUILDENV/etc/resolv.conf"

# --- 2. write the package recipe's non-secret scratch inputs on the HOST
# side (the chroot shares the same underlying filesystem, so anything
# written at $BUILDENV/tmp/X is visible inside the chroot at /tmp/X) — same
# technique build-one-module.sh uses for /tmp/rsync_spec.txt /
# /tmp/package_spec.txt. The GPG key (public, not confidential, but kept to
# the same "never on argv" contract as every other job input) is written
# here too, never echoed. ---------------------------------------------------
echo "deb [trusted=yes] ${REPO_URL} ${APT_SUITE} ${APT_COMPONENTS}" > "$BUILDENV/tmp/pkgbuild-source.list"
if [ -n "$GPG_KEY_ARMOR" ]; then
  printf '%s\n' "$GPG_KEY_ARMOR" > "$BUILDENV/tmp/pkgbuild-key.asc"
else
  log "WARNING: GPG_KEY_ARMOR not set — mmdebstrap will run with no --keyring override for ${REPO_URL}"
fi

# --- 3. the chrooted driver: apt-source config + gpg dearmor + mmdebstrap +
# dpkg-query provenance/ownership capture. A single heredoc-generated
# script (not baked into this module's file_spec — it's a per-job scratch
# artifact, same status as /tmp/rsync_spec.txt above), run once inside the
# chroot so every step shares mmdebstrap/gnupg/dpkg-query from
# /opt/buildenv's own toolchain. Non-secret CLI args only (module/package
# names, paths); ORAS_REGISTRY_PASSWORD is not touched by this driver at
# all (only the later push step, step 5, needs it). ------------------------
cat > "$BUILDENV/tmp/pkg-driver.sh" <<'DRIVER'
#!/bin/sh
set -eu
MODULE="$1"; PACKAGE_NAME="$2"; PACKAGE_VERSION="${3:-}"

mkdir -p /etc/apt/sources.list.d
cp /tmp/pkgbuild-source.list /etc/apt/sources.list.d/pkgbuild.list
KEYRING_ARG=""
if [ -s /tmp/pkgbuild-key.asc ]; then
  gpg --batch --yes --dearmor --output /tmp/pkgbuild-key.gpg /tmp/pkgbuild-key.asc
  KEYRING_ARG="--keyring=/tmp/pkgbuild-key.gpg"
fi

# EVR lockfile pin (campaign 019f6084 item L) — apt's "pkg=version" include
# syntax makes the resolve itself fail (mmdebstrap propagates apt's
# non-zero exit) when that exact version isn't available from REPO_URL, so
# a drifted mirror can never silently ship a different build than the
# lockfile recorded. Only applied when PACKAGE_NAME names exactly one
# package — see this script's PACKAGE_VERSION doc for why a comma-
# separated PACKAGE_NAME can't be pinned from a single EVR value.
INCLUDE_SPEC="$PACKAGE_NAME"
case "$PACKAGE_NAME" in
  *,*)
    if [ -n "$PACKAGE_VERSION" ]; then
      echo "pkg-driver: WARNING: PACKAGE_VERSION set but PACKAGE_NAME names multiple packages ('$PACKAGE_NAME') — building unpinned" >&2
    fi
    ;;
  *)
    if [ -n "$PACKAGE_VERSION" ]; then
      INCLUDE_SPEC="${PACKAGE_NAME}=${PACKAGE_VERSION}"
    fi
    ;;
esac

mkdir -p /tmp/pkgroot
# shellcheck disable=SC2086  # KEYRING_ARG is intentionally unquoted: empty
# when no key was supplied, a single flag token when one was.
mmdebstrap \
  --mode=root \
  --variant=minbase \
  --components="$APT_COMPONENTS" \
  --include="$INCLUDE_SPEC" \
  $KEYRING_ARG \
  --aptopt='Acquire::http::Pipeline-Depth "0"' \
  "$APT_SUITE" /tmp/pkgroot "$REPO_URL"

# Provenance capture — same technique + format as stage1-rootfs.sh.
dpkg-query --admindir=/tmp/pkgroot/var/lib/dpkg -W \
    -f='${Package}\t${Version}\t${Architecture}\n' \
  | LC_ALL=C sort > "/tmp/$MODULE.packages.txt"

# EVR lockfile verification — defense-in-depth alongside the pinned
# mmdebstrap --include above: confirm the version actually installed
# matches the lockfile byte-for-byte before this build is allowed to
# proceed to carve/publish. Catches anything the pinned resolve alone
# might not (e.g. a REPO_URL swap between dispatch and build time that
# happens to still satisfy "=version" against a different repo state).
# Never silently ship a drifted version — die clean instead.
case "$PACKAGE_NAME" in
  *,*) : ;; # multi-package pin unsupported — warning already logged above
  *)
    if [ -n "$PACKAGE_VERSION" ]; then
      ACTUAL_VERSION=$(awk -F'\t' -v pkg="$PACKAGE_NAME" '$1==pkg{print $2}' "/tmp/$MODULE.packages.txt")
      if [ "$ACTUAL_VERSION" != "$PACKAGE_VERSION" ]; then
        echo "pkg-driver: EVR lockfile mismatch for $PACKAGE_NAME: expected $PACKAGE_VERSION, resolved ${ACTUAL_VERSION:-<none>}" >&2
        exit 1
      fi
    fi
    ;;
esac

# Ownership derivation — this module's file_spec (dpkg -L, one absolute
# path per line; directory entries and the "/." root drop out; only paths
# that actually resolve to a file/symlink in the tree survive, same filter
# derive-file-spec.sh's owned_files_for_packages applies).
: > "/tmp/$MODULE.owned.txt"
for pkg in $(printf '%s' "$PACKAGE_NAME" | tr ',' ' '); do
  dpkg-query --admindir=/tmp/pkgroot/var/lib/dpkg -L "$pkg" 2>/dev/null || true
done | while IFS= read -r path; do
  [ "$path" = "/." ] && continue
  if [ -L "/tmp/pkgroot$path" ] || [ -f "/tmp/pkgroot$path" ]; then
    echo "$path"
  fi
done | LC_ALL=C sort -u > "/tmp/$MODULE.owned.txt"
[ -s "/tmp/$MODULE.owned.txt" ] || { echo "pkg-driver: no owned files derived for package(s) '$PACKAGE_NAME'" >&2; exit 1; }
DRIVER
chmod +x "$BUILDENV/tmp/pkg-driver.sh"

log "bootstrapping ${PACKAGE_NAME}${PACKAGE_VERSION:+=${PACKAGE_VERSION}} via mmdebstrap (suite=${APT_SUITE}, components=${APT_COMPONENTS})…"
if ! chroot "$BUILDENV" /bin/bash -c "
  export HOME=/root
  export APT_SUITE='$APT_SUITE' APT_COMPONENTS='$APT_COMPONENTS' REPO_URL='$REPO_URL'
  /bin/sh /tmp/pkg-driver.sh '$MODULE' '$PACKAGE_NAME' '$PACKAGE_VERSION'
" >&2; then
  die "mmdebstrap/dpkg-query bootstrap failed for ${PACKAGE_NAME} (EVR lockfile mismatch or unresolvable pin counts as failure here too — see pkg-driver's own die/exit)"
fi

[ -s "$BUILDENV/tmp/$MODULE.owned.txt" ] || die "pkg-driver produced no owned-file list for ${MODULE}"

# --- 4. carve: mask (excludes) first, then every owned path (includes),
# then a trailing catch-all exclude — IDENTICAL first-match-wins rsync-
# filter shape stage2-carve.sh / derive-file-spec.sh's
# build_rsync_carve_filter use. file_spec (reported below) stays the FULL
# unmasked owned list; only the shipped erofs blob is trimmed by MASK. -----
{
  if [ -n "$MASK" ]; then
    printf '%s\n' "$MASK" | awk 'NF{print "- " $0}'
  fi
  awk '{print "+ " $0}' "$BUILDENV/tmp/$MODULE.owned.txt"
  echo "- *"
} > "$BUILDENV/tmp/pkg_rsync_spec.txt"

log "carving slim rootfs for ${MODULE}…"
mkdir -p "$BUILDENV/tmp/pkgslim"
if ! chroot "$BUILDENV" /bin/bash -c "
  rsync -a --filter='+ */' --filter='. /tmp/pkg_rsync_spec.txt' --prune-empty-dirs /tmp/pkgroot/ /tmp/pkgslim/
" >&2; then
  die "carve (rsync filter) failed for ${MODULE}"
fi

# --- 5. mkfs.erofs — same flags/determinism-clamp shape as stage2-carve.sh,
# anchored on SHA (the batch's repo-sync snapshot token, the closest
# analog to a commit date this recipe has — see the ENV CONTRACT's SHA
# note) rather than a git commit date. Unparseable/blank SHA falls back to
# epoch 0 (documented residual-nondeterminism posture, not silently
# ignored — see the file header). --------------------------------------------
SOURCE_DATE_EPOCH="$(date -u -d "$SHA" +%s 2>/dev/null || echo 0)"
log "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (derived from SHA=${SHA})"
EROFS_UUID=$(uuidgen --sha1 --namespace @oid --name "${MODULE}@${SHA}")
if ! chroot "$BUILDENV" /bin/bash -c "
  export SOURCE_DATE_EPOCH='$SOURCE_DATE_EPOCH'
  mkfs.erofs -zlz4hc --all-root -T '$SOURCE_DATE_EPOCH' --all-time -U '$EROFS_UUID' \
    /tmp/$MODULE.erofs /tmp/pkgslim
" >&2; then
  die "mkfs.erofs failed for ${MODULE}"
fi
[ -s "$BUILDENV/tmp/$MODULE.erofs" ] || die "mkfs.erofs reported success but /tmp/$MODULE.erofs is missing/empty"

EROFS_ROOT=$(chroot "$BUILDENV" /bin/bash -c "fsverity digest --hash-alg=sha256 /tmp/$MODULE.erofs" | awk '{print $1}')
EROFS_SIZE=$(chroot "$BUILDENV" /bin/bash -c "stat -c%s /tmp/$MODULE.erofs")
[ -n "$EROFS_ROOT" ] || die "could not compute fsverity digest for ${MODULE}"

# --- 6. push — SAME script, SAME invocation shape module-forge-build.sh's
# step 5 uses (reads /tmp/$MODULE.erofs, .erofs.meta is NOT required by
# push.sh itself — only by module-forge-build.sh's own RESULT JSON
# assembly, which this script replaces with the values computed above —
# and /tmp/$MODULE.packages.txt, already written by pkg-driver.sh). --------
log "pushing ${MODULE}:${OCI_REF} to ${ORAS_REGISTRY} (unsigned)…"
export ORAS_REGISTRY_USERNAME="$ORAS_REGISTRY_USER"
export ORAS_REGISTRY_PASSWORD
PUSH_OUT="$BUILDENV/tmp/module-forge-package-push-output.env"
if ! chroot "$BUILDENV" /bin/bash -c "
  export HOME=/root
  cd /mnt/workspace
  bash /opt/module-build/push.sh \
    --module '$MODULE' --sha '$SHA' --workspace /mnt/workspace \
    --tag '$OCI_REF' --registry '$ORAS_REGISTRY' \
    --output-file /tmp/module-forge-package-push-output.env
" >&2; then
  die "push.sh failed for ${MODULE}"
fi
unset ORAS_REGISTRY_USERNAME ORAS_REGISTRY_PASSWORD

[ -s "$PUSH_OUT" ] || die "push.sh reported success but wrote no output at $PUSH_OUT"
EROFS_REF=$(sed -n 's/^erofs_ref=//p' "$PUSH_OUT" | head -n1)
[ -n "$EROFS_REF" ] || die "push.sh output at $PUSH_OUT has no erofs_ref= line"

log "resolving pushed digest for ${EROFS_REF}…"
OCI_DIGEST=$(chroot "$BUILDENV" /bin/bash -c "
  export HOME=/root
  oras manifest fetch --descriptor '$EROFS_REF'
" 2>/dev/null | jq -r '.digest')
if [ -z "$OCI_DIGEST" ] || [ "$OCI_DIGEST" = "null" ]; then
  die "could not resolve oci_digest for $EROFS_REF"
fi

# --- 7. RESULT JSON — platform-module four-key contract + file_spec (the
# FULL unmasked owned-file list from step 3, one path per array entry). ----
RESULT_JSON=$(jq -nc \
  --arg digest "$OCI_DIGEST" \
  --arg root "$EROFS_ROOT" \
  --argjson size "$EROFS_SIZE" \
  --arg sha "$SHA" \
  --slurpfile spec <(jq -R -s 'split("\n") | map(select(length>0))' "$BUILDENV/tmp/$MODULE.owned.txt") \
  '{oci_digest: $digest, fsverity_root: $root, size: $size, built_from_sha: $sha, file_spec: $spec[0]}')

if [ -n "$RESULT_FILE" ]; then
  printf '%s\n' "$RESULT_JSON" > "$RESULT_FILE"
fi
log "done: ${MODULE}@${SHA} (package=${PACKAGE_NAME}) -> ${EROFS_REF} (${OCI_DIGEST})"
printf '%s\n' "$RESULT_JSON"
