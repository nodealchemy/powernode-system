#!/usr/bin/env bash
# stage1-rootfs.sh — Stage 1 of the platform module build pipeline:
# mmdebstrap fat rootfs bootstrap from package_spec + per-module apt-source
# hooks, plus the inc5 package-provenance (dpkg-query) capture.
#
# Extracted VERBATIM (campaign 019f5885 inc6 — pure refactor, no logic
# changes) from the "Stage 1 — bootstrap fat rootfs (mmdebstrap +
# package_spec)" step of .gitea/workflows/build-platform-modules.yaml: same
# commands, same order, same env semantics, same hardcoded /tmp/* scratch
# paths — so the fat rootfs + provenance capture this produces are
# byte-identical to the pre-refactor inline step. The workflow step is now
# a thin invocation of this script; a future on-node/native build (inc7+,
# driven by build-one-module.sh in this same directory) runs the identical
# script with no Gitea Actions context at all.
#
# Only two values varied by workflow context in the original inline step —
# both threaded through as explicit CLI args below (never read from the
# process environment, so this script has no Actions-env-var dependency):
#   $MODULE       — was set via GITHUB_ENV by the "Resolve build slot" step
#                   (untouched); now --module.
#   $APT_SNAPSHOT — was the step's own `env:` block, sourced from
#                   steps.manifest.outputs.apt_snapshot (the "Parse
#                   manifest" step, untouched); now --apt-snapshot.
# Every /tmp/* path below (fat rootfs, hooks dir, package_spec.txt, the
# packages provenance file) is the SAME hardcoded literal the inline step
# used — not parameterized, because none of them are sourced from Actions
# context; they're the pipeline's existing shared-/tmp convention (the same
# container filesystem is shared by every step in a job), unchanged here.
#
# Usage:
#   stage1-rootfs.sh --module MODULE [--apt-snapshot SNAPSHOT_OR_none]
#
# Required:
#   --module MODULE            module slug
#
# Optional:
#   --apt-snapshot VALUE        manifest's build.apt_snapshot, or the
#                               literal string "none" (default)
#
# Reads:  /tmp/package_spec.txt (produced by the workflow's untouched
#         "Parse manifest" step)
# Writes: /tmp/fat (the bootstrapped rootfs), /tmp/hooks/* (apt-source
#         hooks for log-forwarder-vector / storage-tools),
#         /tmp/$MODULE.packages.txt (resolved-package provenance)
#
# Exit: non-zero on any mmdebstrap/dpkg-query failure (set -euo pipefail
# propagates the first one).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: stage1-rootfs.sh --module MODULE [--apt-snapshot SNAPSHOT_OR_none]

Stage 1 of the module build pipeline: mmdebstrap fat rootfs bootstrap +
package-provenance capture. See the file header for the full option
reference and the workflow-env-var mapping.
EOF
}

die() {
  echo "stage1-rootfs.sh: error: $*" >&2
  exit 2
}

MODULE=""
APT_SNAPSHOT="none"

while [ $# -gt 0 ]; do
  case "$1" in
    --module)
      [ $# -ge 2 ] || die "--module requires an argument"
      MODULE="$2"; shift 2 ;;
    --apt-snapshot)
      [ $# -ge 2 ] || die "--apt-snapshot requires an argument"
      APT_SNAPSHOT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[ -n "$MODULE" ] || { usage >&2; die "--module is required"; }

# ---------------------------------------------------------------------------
# Everything below is VERBATIM from the workflow's Stage 1 step body — no
# text changed beyond this comment block. $MODULE/$APT_SNAPSHOT are now
# populated by the arg parsing above instead of the shell/GITHUB_ENV
# environment; every other reference (including all /tmp/* paths) is
# byte-for-byte identical to the inline step.
# ---------------------------------------------------------------------------

# mmdebstrap produces a minimal Ubuntu noble rootfs at
# /tmp/fat with `ca-certificates` + every package the
# module's manifest declared in package_spec. --mode=root
# avoids any namespace setup (we're running as root inside
# the Trixie CI container).
#
# The mmdebstrap output is functionally identical to what
# `buildah bud` against templates/module-repo/Containerfile
# produced — pinned base image + apt install + static
# ca-certs. We trade buildah's OCI-runtime isolation for a
# plain chroot, which is fine for the CI hermeticity envelope
# (the runner container itself is the security boundary).
#
# apt-snapshot pin (campaign 019f5885 inc5 — determinism
# hardening): archive.ubuntu.com serves whatever the current
# apt index is on the day the build runs, so two builds of the
# SAME commit on different days can resolve different package
# versions — a hard blocker for a bit-reproducible erofs.
# snapshot.ubuntu.com serves a frozen historical index at the
# module manifest's declared `build.apt_snapshot` timestamp, so
# every rebuild of an unchanged module resolves the identical
# package set. "none" (declared or the field's absence — both
# normalize to this string in the "Parse manifest" step above)
# is the documented per-module opt-out for the case where
# snapshot.ubuntu.com hasn't caught up on a package this module
# needs (coverage/lag risk) — it keeps today's live-mirror
# behavior unchanged.
if [[ "${APT_SNAPSHOT:-none}" != "none" ]]; then
  base_url="https://snapshot.ubuntu.com/ubuntu/${APT_SNAPSHOT}/"
  echo "[stage-1] apt_snapshot=${APT_SNAPSHOT} — pinning mmdebstrap base_url to ${base_url}"
else
  base_url="http://archive.ubuntu.com/ubuntu/"
  echo "[stage-1] apt_snapshot=none — using live ${base_url} (per-module opt-out, or manifest hasn't pinned yet)"
fi
pkgs="ca-certificates"
if [ -s /tmp/package_spec.txt ]; then
  pkgs="${pkgs},$(tr '\n' ',' < /tmp/package_spec.txt | sed 's/,$//')"
fi

# Some modules declare packages that aren't in Ubuntu's main/universe:
#   - log-forwarder-vector ships `vector` (Timber/Datadog apt repo)
#   - storage-tools ships `gcsfuse` (Google Cloud apt repo)
# For those modules, register the upstream apt source + key via an
# --essential-hook so the package is resolvable when mmdebstrap's
# --include step runs. Hook executes after essential packages
# install but BEFORE the manifest's package_spec packages.
#
# DOCUMENTED REPRODUCIBILITY WAIVER (campaign 019f5885 inc5): both
# hooks below point at the vendor's live apt repo
# (apt.vector.dev, packages.cloud.google.com) — neither vendor
# offers a snapshot-pinned mirror we can substitute the way
# snapshot.ubuntu.com stands in for archive.ubuntu.com above. Two
# builds of log-forwarder-vector / storage-tools can therefore
# still pick up a newer `vector` / `gcsfuse` package between runs
# even with apt_snapshot pinned — this is residual, irreducible
# per-module nondeterminism until/unless either vendor ships a
# snapshot service. Every other module's apt_snapshot pin is
# unaffected.
hook_args=()
mkdir -p /tmp/hooks
case "$MODULE" in
  log-forwarder-vector)
    # Post-Datadog-acquisition, vector's apt key moved to
    # keys.datadoghq.com (DATADOG_APT_KEY_CURRENT.public) and
    # the legacy https://apt.vector.dev/vector.gpg returns 404.
    # The repo line is also `vector-<major>` not `main` per
    # vector's setup.vector.dev install script. Without these
    # updates the hook dies with: "gpg: not found" (fixed via
    # gnupg install above) + "curl: 404" (this URL change).
    cat > /tmp/hooks/essential00-vector-source.sh <<'EOF'
#!/bin/sh
# At essential-hook stage apt isn't yet installed in the chroot
# (it comes in via mmdebstrap's --include pass that runs AFTER
# this hook). Just drop the key + sources.list into place; the
# subsequent apt-get pass will see them. Trying to chroot in
# and apt-get update here dies with "chroot: failed to run
# command 'apt-get': No such file or directory".
set -eu
ROOT="$1"
mkdir -p "$ROOT/etc/apt/keyrings" "$ROOT/etc/apt/sources.list.d"
curl -fsSL https://keys.datadoghq.com/DATADOG_APT_KEY_CURRENT.public | gpg --dearmor > "$ROOT/etc/apt/keyrings/vector.gpg"
echo "deb [signed-by=/etc/apt/keyrings/vector.gpg] https://apt.vector.dev/ stable vector-0" > "$ROOT/etc/apt/sources.list.d/vector.list"
EOF
    chmod +x /tmp/hooks/essential00-vector-source.sh
    hook_args+=("--hook-directory=/tmp/hooks")
    ;;
  storage-tools)
    cat > /tmp/hooks/essential00-gcsfuse-source.sh <<'EOF'
#!/bin/sh
# Same essential-hook-stage constraint as the vector hook above:
# apt isn't yet in the chroot, so we only drop the key +
# sources.list. mmdebstrap's --include pass will pick them up.
set -eu
ROOT="$1"
mkdir -p "$ROOT/etc/apt/keyrings" "$ROOT/etc/apt/sources.list.d"
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor > "$ROOT/etc/apt/keyrings/google-cloud.gpg"
echo "deb [signed-by=/etc/apt/keyrings/google-cloud.gpg] https://packages.cloud.google.com/apt gcsfuse-noble main" > "$ROOT/etc/apt/sources.list.d/gcsfuse.list"
EOF
    chmod +x /tmp/hooks/essential00-gcsfuse-source.sh
    hook_args+=("--hook-directory=/tmp/hooks")
    ;;
  # gitea-act-runner needs no apt-source hook: its Docker packages
  # (docker.io + docker-buildx) live in Ubuntu noble's own universe
  # component, already indexed by mmdebstrap's base apt-get update.
esac

mmdebstrap \
  --mode=root \
  --variant=minbase \
  --components=main,universe \
  "${hook_args[@]}" \
  --include="$pkgs" \
  --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \
  --aptopt='Acquire::http::Pipeline-Depth "0"' \
  noble /tmp/fat \
  "$base_url"

# Build provenance: capture the exact resolved package set (SBOM
# stepping stone — campaign 019f5885 inc5; full SLSA provenance
# is separately queued as 019f3112-f719-7152-aeac-51a3e833259f,
# out of scope here). mmdebstrap leaves a normal dpkg database at
# /tmp/fat/var/lib/dpkg — query it via --admindir from the
# RUNNER's own dpkg-query rather than chrooting: same technique
# this workflow already uses for the apt-closure-sha256
# annotation (APT_PROBE_MODE=local, "the runner IS
# debian:trixie-slim"), and dpkg's on-disk database format is
# stable across Debian/Ubuntu regardless of which one is being
# queried. Captured HERE (immediately after mmdebstrap, before
# Stage 1.5 layers any Class-B content that isn't apt-installed)
# so this is exactly "what apt resolved for package_spec", not a
# mix of apt + hand-staged binaries.
dpkg-query --admindir=/tmp/fat/var/lib/dpkg -W \
    -f='${Package}\t${Version}\t${Architecture}\n' \
  | LC_ALL=C sort > "/tmp/$MODULE.packages.txt"
echo "[stage-1] captured $(wc -l < "/tmp/$MODULE.packages.txt") resolved packages to /tmp/$MODULE.packages.txt"
