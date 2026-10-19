#!/usr/bin/env bash
# Resolve the core (powernode-platform) commit a CI run of this extension tests
# against. IMP-ddacfe8bde28.
#
# Usage: ci-resolve-core-ref.sh <core-remote-url> <wanted-branch>
# Env:   CORE_READ_TOKEN  optional read token for an HTTP remote
# Prints key=value lines for $GITHUB_OUTPUT:
#   ref=<branch>  sha=<commit>  source=same-name|default
#
# Rule: the core branch named exactly like this run's branch when core has one
# (a feature pair pushed to both repos, or master against master), otherwise the
# core default branch, read from the remote's HEAD rather than assumed. The SHA
# is resolved ONCE so every job of a run checks out the same core commit; before
# this, each job took the default branch HEAD as of its own start time.
#
# Known limit of the rule: a PR from feature/x tests core feature/x, while the
# merge push to develop tests core develop, so the two can disagree until core's
# feature/x is merged too.
set -euo pipefail

url=${1:?usage: ci-resolve-core-ref.sh <core-remote-url> <wanted-branch>}
wanted=${2:-}

# The token reaches git through an askpass helper that reads it from the
# environment: never in argv, never on stdout (which the caller writes to
# $GITHUB_OUTPUT), and never re-encoded into a form the runner's secret masking
# would not recognise. Gitea basic auth ignores the username.
askpass=""
cleanup() { [ -z "$askpass" ] || rm -f "$askpass"; }
trap cleanup EXIT

# ls-remote runs OUTSIDE the checkout: actions/checkout leaves an
# http.<server>.extraheader carrying the job's own token, scoped to THIS repo,
# and git sends it before any askpass challenge, so the core read token was
# never offered and Gitea answered "Repository not found".
remote() {
  ( cd / && remote_in_neutral_dir "$@" )
}

remote_in_neutral_dir() {
  if [ -n "${CORE_READ_TOKEN:-}" ]; then
    if [ -z "$askpass" ]; then
      askpass=$(mktemp)
      printf '%s\n' '#!/bin/sh' \
        'case "$1" in Username*) echo x-access-token ;; *) printf "%s\n" "$CORE_READ_TOKEN" ;; esac' >"$askpass"
      chmod 700 "$askpass"
    fi
    GIT_ASKPASS=$askpass GIT_TERMINAL_PROMPT=0 git ls-remote "$@"
  else
    GIT_TERMINAL_PROMPT=0 git ls-remote "$@"
  fi
}

# On a failed read, say WHY without printing the token: the account it
# authenticates as and the repo API's status for it. Gitea answers "Repository
# not found" both for a missing repo and for a token that cannot see it.
diagnose() {
  [ -n "${CORE_READ_TOKEN:-}" ] || { echo "::error::no core read token is set (CORE_READ_TOKEN / PLATFORM_READ_TOKEN secret)" >&2; return; }
  command -v curl >/dev/null || return
  local base path login repo_code
  base=$(sed -E 's#^(https?://[^/]+)/.*#\1#' <<<"$url")
  path=$(sed -E 's#^https?://[^/]+/##; s#\.git$##' <<<"$url")
  login=$(curl -s -H "Authorization: token $CORE_READ_TOKEN" "$base/api/v1/user" | sed -nE 's/.*"login":"([^"]*)".*/\1/p')
  repo_code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $CORE_READ_TOKEN" "$base/api/v1/repos/$path")
  echo "::error::core read token authenticates as '${login:-<rejected>}'; GET /api/v1/repos/$path -> $repo_code (needs 200: the token's user must read that repo and the token must allow private repos with read:repository)" >&2
}

ref="" sha="" source=""

if [ -n "$wanted" ]; then
  heads=$(remote --heads "$url" "$wanted") || { diagnose; exit 128; }
  # ls-remote patterns match trailing path components; keep only the exact ref.
  sha=$(awk -v want="refs/heads/$wanted" '$2 == want { print $1 }' <<<"$heads")
  [ -n "$sha" ] && ref=$wanted source=same-name
fi

if [ -z "$sha" ]; then
  head=$(remote --symref "$url" HEAD) || { diagnose; exit 128; }
  ref=$(awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2 }' <<<"$head")
  sha=$(awk '$1 != "ref:" && $2 == "HEAD" { print $1 }' <<<"$head")
  source=default
fi

if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || [ -z "$ref" ]; then
  echo "could not resolve a core commit from $url (wanted '${wanted}')" >&2
  exit 1
fi

printf 'ref=%s\nsha=%s\nsource=%s\n' "$ref" "$sha" "$source"
