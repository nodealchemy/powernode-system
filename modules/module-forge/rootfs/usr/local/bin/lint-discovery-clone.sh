#!/usr/bin/env bash
# lint-discovery-clone.sh — phase 1 of improvement discovery's runner half
# (campaign 01a08c9b D1b): clone ONE repository into "$WORKDIR/src".
#
# Platform-owned. The agent's ci.lint_discovery handler runs it with ZERO
# arguments, as the unprivileged sandbox user, with an environment the agent
# builds from scratch (nothing is inherited from the agent). Inputs:
#   REPO_URL, REPO_REF, WORKDIR, HOME, TMPDIR, XDG_CACHE_HOME
#   GIT_ASKPASS, LINT_GIT_HOST, LINT_GIT_USERNAME, LINT_GIT_TOKEN
#   GIT_CONFIG_NOSYSTEM, GIT_CONFIG_GLOBAL, GIT_CONFIG_COUNT/KEY_n/VALUE_n
#   GIT_ALLOW_PROTOCOL, GIT_HTTP_LOW_SPEED_LIMIT/TIME
#   LINT_CLONE_TIMEOUT_SECONDS, LINT_KILL_AFTER_SECONDS (the agent derives the
#   bound from what is left of the lease)
#
# This phase runs git and nothing from the repository: a clone runs no hooks
# and no filters, because no config names any. The lint phase is a separate
# process that never receives the credential.
#
# CREDENTIAL SAFETY: never `set -x`, never echo or print the environment.
# stdout stays empty; diagnostics go to stderr.
set -euo pipefail

: "${REPO_URL:?REPO_URL is required}"
: "${WORKDIR:?WORKDIR is required}"
: "${HOME:?HOME is required}"
: "${TMPDIR:?TMPDIR is required}"
: "${XDG_CACHE_HOME:?XDG_CACHE_HOME is required}"
: "${LINT_CLONE_TIMEOUT_SECONDS:?LINT_CLONE_TIMEOUT_SECONDS is required}"
: "${LINT_KILL_AFTER_SECONDS:?LINT_KILL_AFTER_SECONDS is required}"

case "$REPO_URL" in
  https://*) ;;
  *)
    echo "lint-discovery-clone: refusing a clone URL that is not https" >&2
    exit 64
    ;;
esac

mkdir -p "$HOME" "$TMPDIR" "$XDG_CACHE_HOME"

clone_args=(--quiet --depth 1 --no-tags)
if [ -n "${REPO_REF:-}" ]; then
  clone_args+=(--branch "$REPO_REF")
fi

timeout -k "$LINT_KILL_AFTER_SECONDS" "$LINT_CLONE_TIMEOUT_SECONDS" \
  git clone "${clone_args[@]}" -- "$REPO_URL" "$WORKDIR/src" >&2
