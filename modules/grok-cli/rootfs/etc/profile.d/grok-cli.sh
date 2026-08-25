# shellcheck shell=sh
# grok-cli.sh — export XAI_API_KEY into interactive login shells from the
# key staged by the grok-cli credential unit.
#
# WHY THIS FILE EXISTS. claude-tmux hands its key to a tmux pane it starts
# itself, so it needs no shell hook. This module deliberately starts no
# session (see manifest description), which means the LOGIN SHELL is the
# only consumer — an operator, or an external_cli dev-loop executor, typing
# `grok`. Without this shim the key would be staged at /run/grok-cli/api_key
# and nothing would ever read it.
#
# SOURCED, not executed: this runs in the caller's shell. Three hard rules
# follow from that and none of them are style preferences:
#   * never `set -e`/`set -u` — it would apply to the operator's interactive
#     shell and abort it on the next unset variable;
#   * never exit — it would log the operator out;
#   * never write to stdout — profile.d output corrupts non-interactive
#     consumers such as `scp` and `rsync`.
# So every branch here is a silent no-op.
#
# NOT logging the key is a rule (CryptoMaterialSafety), and the value never
# reaches stdout, a trace, or an argv here. It DOES land in this shell's
# environment, which is readable through /proc/<pid>/environ — by that same
# user and by root only, which is the same exposure `export XAI_API_KEY=...`
# in a dotfile would have. The staged file itself is 0600 and owned by the
# credential unit's configured user, so a different unprivileged user on the
# node reads neither the file nor this variable.
#
# Skipped when XAI_API_KEY is already set: an operator's own explicit key,
# or a per-invocation override, must win over the staged one.
if [ -z "${XAI_API_KEY:-}" ] && [ -r /run/grok-cli/api_key ]; then
	XAI_API_KEY=$(cat /run/grok-cli/api_key 2>/dev/null) || XAI_API_KEY=""
	if [ -n "$XAI_API_KEY" ]; then
		export XAI_API_KEY
	else
		# Staged file present but empty/unreadable: leave nothing behind
		# rather than exporting an empty credential, which would make the
		# CLI fail with an auth error instead of the clearer "no key set".
		unset XAI_API_KEY
	fi
fi
