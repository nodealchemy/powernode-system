#!/usr/bin/env bash
# lint-discovery.sh — phase 2 of improvement discovery's runner half (campaign
# 01a08c9b D1b): lint the clone in "$WORKDIR/src" with the repository's OWN
# bundle, and print the raw linter output as ONE JSON line on stdout:
#   {"linters":{"ruby":{"status":"ran","exitstatus":1,"output":"..."}, ...}}
# The platform parses that output and files the findings; this script decides
# nothing about what a finding is.
#
# Platform-owned. The agent's ci.lint_discovery handler runs it with ZERO
# arguments, as the unprivileged sandbox user, in a process separate from the
# clone, with an environment built from scratch that carries NO credential.
# Repository code runs here (a Gemfile evaluated by bundle install, rubocop
# plugins, an eslint config, node_modules/.bin), so nothing it can reach may
# carry a credential. The script refuses to start if one is present.
#
# Inputs: WORKDIR, HOME, TMPDIR, XDG_CACHE_HOME, PATH, LANG, and from the agent:
#   LINT_MAX_OUTPUT_BYTES    the platform's parse limit for one linter's output
#   LINT_TIMEOUT_SECONDS     the bound on each timed step, derived by the agent
#                            from what is left of the lease
#   LINT_KILL_AFTER_SECONDS  the grace before a step that ignores TERM is killed
# Every step runs under `timeout -k`, so the script always ends, and reports the
# linters that finished, inside the agent's bound on the whole phase.
#
# Linter statuses: "ran" (with exitstatus and output); "missing_<program>"
# (ruby, bundle, node, npm or npx is not installed on this runner);
# "no_package_json" (a tsconfig or ESLint config with no package.json at the
# repository root); "timeout" (a step ran out of its bound); "killed" (a
# signal ended a step, so whatever it printed is not a whole report);
# "install_failed" (the repository's own bundle would not install);
# "output_truncated" (the linter printed more than LINT_MAX_OUTPUT_BYTES; none
# of it is sent, because the platform never parses a cut report). Anything but
# "ran" is a did-not-measure status on the platform, never a clean result.
set -euo pipefail

: "${WORKDIR:?WORKDIR is required}"

if [ -n "${LINT_GIT_TOKEN:-}${LINT_GIT_USERNAME:-}${GIT_ASKPASS:-}" ]; then
  echo "lint-discovery: refusing to run repository code with a credential in the environment" >&2
  exit 64
fi

log() { echo "lint-discovery: $*" >&2; }

# require_positive <name> <value>
require_positive() {
  case "$2" in
    '' | *[!0-9]* | 0)
      echo "lint-discovery: $1 must be a positive integer" >&2
      exit 64
      ;;
  esac
}
require_positive LINT_MAX_OUTPUT_BYTES "${LINT_MAX_OUTPUT_BYTES:-}"
require_positive LINT_TIMEOUT_SECONDS "${LINT_TIMEOUT_SECONDS:-}"
require_positive LINT_KILL_AFTER_SECONDS "${LINT_KILL_AFTER_SECONDS:-}"

src="$WORKDIR/src"
out="$WORKDIR/out"
mkdir -p "$out" "${HOME:-$WORKDIR/home}" "${TMPDIR:-$WORKDIR/tmp}"
export npm_config_cache="${XDG_CACHE_HOME:-$WORKDIR/cache}/npm"

cd "$src"

set_status() { printf '%s' "$2" > "$out/$1.status"; }

# timed <command...> — one step under the step bound: TERM at the bound, KILL
# after the grace.
timed() { timeout -k "$LINT_KILL_AFTER_SECONDS" "$LINT_TIMEOUT_SECONDS" "$@"; }

# step_failure <rc> — the did-not-measure status for a step's exit status, or
# nothing when the step ran to its own end. 124: the bound ran out. 128 and
# over: a signal ended it (timeout answers 137 when its -k had to kill).
step_failure() {
  if [ "$1" -eq 124 ]; then
    printf timeout
  elif [ "$1" -ge 128 ]; then
    printf killed
  fi
}

# install_state <rc> — "ok", or the did-not-measure status for an install.
install_state() {
  local failure
  failure="$(step_failure "$1")"
  if [ -n "$failure" ]; then
    printf '%s' "$failure"
  elif [ "$1" -eq 0 ]; then
    printf ok
  else
    printf install_failed
  fi
}

# run_linter <key> <command...> — captures stdout and the exit status. Output
# over the limit is reported as output_truncated and never sent.
run_linter() {
  local key="$1"
  shift
  if ! command -v "$1" >/dev/null 2>&1; then
    set_status "$key" "missing_$1"
    return 0
  fi
  local rc=0 failure size
  timed "$@" > "$out/$key.raw" 2> "$out/$key.err" || rc=$?
  failure="$(step_failure "$rc")"
  if [ -n "$failure" ]; then
    rm -f "$out/$key.raw"
    set_status "$key" "$failure"
    return 0
  fi
  size="$(wc -c < "$out/$key.raw")"
  if [ "$size" -gt "$LINT_MAX_OUTPUT_BYTES" ]; then
    rm -f "$out/$key.raw"
    set_status "$key" output_truncated
    return 0
  fi
  mv "$out/$key.raw" "$out/$key.out"
  printf '%s' "$rc" > "$out/$key.rc"
  set_status "$key" ran
}

# compgen, not ls: `ls a* b*` fails whenever EITHER glob matches nothing.
has_eslint_config() {
  compgen -G '.eslintrc*' >/dev/null || compgen -G 'eslint.config.*' >/dev/null
}

# Ruby: the repository's own Gemfile, installed into the workdir.
if [ -f Gemfile ]; then
  if ! command -v ruby >/dev/null 2>&1; then
    set_status ruby missing_ruby
  elif ! command -v bundle >/dev/null 2>&1; then
    set_status ruby missing_bundle
  else
    export BUNDLE_PATH="$WORKDIR/bundle" BUNDLE_GEMFILE="$src/Gemfile"
    rc=0
    timed bundle install --jobs 4 --quiet >&2 || rc=$?
    ruby_state="$(install_state "$rc")"
    if [ "$ruby_state" = ok ]; then
      run_linter ruby bundle exec rubocop --format json
    else
      set_status ruby "$ruby_state"
    fi
  fi
fi

# TypeScript and ESLint: the repository's own package.json, installed from its
# lockfile without install scripts. A config with no package.json beside it is
# still reported, so a detected linter never silently drops out.
if [ -f tsconfig.json ] || has_eslint_config; then
  if [ ! -f package.json ]; then
    node_state=no_package_json
  elif ! command -v node >/dev/null 2>&1; then
    node_state=missing_node
  elif ! command -v npm >/dev/null 2>&1; then
    node_state=missing_npm
  else
    rc=0
    timed npm ci --ignore-scripts --no-audit --no-fund --silent >&2 || rc=$?
    node_state="$(install_state "$rc")"
  fi

  if [ -f tsconfig.json ]; then
    if [ "$node_state" = ok ]; then
      run_linter typescript npx --no-install tsc --noEmit --pretty false
    else
      set_status typescript "$node_state"
    fi
  fi

  if has_eslint_config; then
    if [ "$node_state" = ok ]; then
      run_linter javascript_lint npx --no-install eslint --format json .
    else
      set_status javascript_lint "$node_state"
    fi
  fi
fi

# The result line. Every large value travels through a file or stdin, never as
# one argument: Linux caps a single exec argument at 128 KiB.
result='{}'
for status_file in "$out"/*.status; do
  [ -e "$status_file" ] || continue
  key="$(basename "$status_file" .status)"
  status="$(cat "$status_file")"
  if [ "$status" = ran ]; then
    result="$(printf '%s' "$result" | jq -c --arg k "$key" --rawfile o "$out/$key.out" \
      --argjson rc "$(cat "$out/$key.rc")" '.[$k] = {status: "ran", exitstatus: $rc, output: $o}')"
  else
    result="$(printf '%s' "$result" | jq -c --arg k "$key" --arg s "$status" '.[$k] = {status: $s}')"
  fi
done

log "done"
printf '%s' "$result" | jq -c '{linters: .}'
