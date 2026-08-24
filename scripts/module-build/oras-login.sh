#!/usr/bin/env bash
# oras-login.sh — authenticate oras against the module registry, early.
# =============================================================================
# WHY THIS EXISTS. The content-addressed build skip (019ff2aa) was INERT from
# the day it shipped, and silently so. should-skip-build.sh runs at the TOP of
# build-one-module.sh and does:
#
#     oras manifest fetch $REGISTRY/$OWNER/$MODULE:latest
#
# but the only `oras login` in the pipeline lives in push.sh, which runs at the
# END of the build. So that fetch was always unauthenticated, the private Gitea
# registry answered 401, and should-skip-build.sh mapped the failure onto its
# catch-all "no published manifest (first publish, or registry unreachable)"
# -> BUILD. Every module, every run. Measured 2026-08-24: redis, whose module
# tree had not changed, rebuilt with a fresh digest and logged exactly that line.
#
# The failure was invisible because it is INDISTINGUISHABLE FROM THE FEATURE
# BEING OFF: the skip fails safe to BUILD, so an always-unauthorised fetch looks
# exactly like "nothing was skippable this run". Nothing was ever slower or
# wrong — it just never saved anything.
#
# FAIL-SAFE, DELIBERATELY. Every failure here is non-fatal and silent-ish: a
# missing credential, an unreachable registry, oras not on PATH. The caller runs
# this best-effort before the skip check, and a failed login simply leaves the
# fetch unauthenticated — which returns BUILD, the same conservative answer as
# before. Authentication must never be able to FAIL a build that would
# otherwise have succeeded.
#
# SECRETS. The password is read from the environment and handed to oras on
# stdin. It is never echoed, never passed as an argv element (argv is visible in
# /proc), and never written to a file by this script.
#
# Usage: bash oras-login.sh [registry-host]
#   registry-host defaults to $APT_REGISTRY, then git.powernode.org — the same
#   default should-skip-build.sh resolves, so the host we authenticate against
#   is the host it queries.
#
# Exit status is always 0. The caller cannot act on a failure anyway.

REGISTRY_HOST="${1:-${APT_REGISTRY:-git.powernode.org}}"

if ! command -v oras >/dev/null 2>&1; then
  echo "[oras-login] oras not on PATH — skipping login (skip-check will read as BUILD)" >&2
  exit 0
fi

if [ -z "${ORAS_REGISTRY_USERNAME:-}" ] || [ -z "${ORAS_REGISTRY_PASSWORD:-}" ]; then
  echo "[oras-login] no registry credentials in env — skipping login (skip-check will read as BUILD)" >&2
  exit 0
fi

# --password-stdin, matching push.sh's own login: oras does NOT read
# ORAS_REGISTRY_USERNAME/PASSWORD by itself.
if oras login "$REGISTRY_HOST" \
     --username "$ORAS_REGISTRY_USERNAME" \
     --password-stdin <<< "$ORAS_REGISTRY_PASSWORD" >/dev/null 2>&1; then
  echo "[oras-login] authenticated to $REGISTRY_HOST" >&2
else
  echo "[oras-login] login to $REGISTRY_HOST FAILED — skip-check will read as BUILD" >&2
fi

exit 0
