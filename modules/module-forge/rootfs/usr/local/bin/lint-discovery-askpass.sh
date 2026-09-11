#!/bin/sh
# lint-discovery-askpass.sh — GIT_ASKPASS helper for lint-discovery-clone.sh
# (campaign 01a08c9b D1b).
#
# git runs this with its prompt as $1 and reads the answer from stdout. The
# answers come from the environment the agent set, so the repository
# credential is never in a clone URL, a command-line argument or a log line.
#
# It answers ONLY the two prompts git asks for the one host the platform named
# (LINT_GIT_HOST, host[:port]), matched exactly:
#   Username for 'https://HOST':
#   Password for 'https://USER@HOST':
# Any other prompt (another host, a redirect, a submodule elsewhere) gets an
# empty answer, never the token. The clone runs with no git config, so git
# never puts a path in the prompt. Never echo anything else here: stdout IS
# the answer.
#
# Both patterns are double-quoted, so the host and username expand as LITERAL
# text: a `*` or `?` in either matches only itself and never widens the match
# (pinned by TestAskpass_MatchesTheHostAndUserLiterally).
user="${LINT_GIT_USERNAME:-x-access-token}"
case "$1" in
  "Username for 'https://${LINT_GIT_HOST}'"*) printf '%s\n' "$user" ;;
  "Password for 'https://${user}@${LINT_GIT_HOST}'"*) printf '%s\n' "${LINT_GIT_TOKEN:-}" ;;
  *) printf '\n' ;;
esac
