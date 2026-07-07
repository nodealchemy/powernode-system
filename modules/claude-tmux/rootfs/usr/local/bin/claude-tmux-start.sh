#!/bin/sh
# claude-tmux-start.sh — starts (or, on a systemd restart, no-ops into) the
# managed "claude-code" tmux session and launches the Claude Code CLI
# inside it with ANTHROPIC_API_KEY set from the credential file staged by
# claude-tmux-fetch-credential.sh.
#
# Runs as the unprivileged session user (systemd User=/Group=). Dedicated
# tmux socket (-L claude-tmux) so this systemd-managed server never
# collides with the operator's own ad-hoc `tmux` sessions.
#
# The credential is deliberately NOT passed as a tmux/systemd argv (would
# leak into `ps`/`/proc/<pid>/cmdline` for any local user) — the pane's own
# shell reads-then-deletes the runtime file, so the secret only ever
# exists in that shell's environment table, never in a process listing.
set -eu

SOCKET=claude-tmux
SESSION=claude-code
RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/claude-tmux}"
CRED_FILE="$RUNTIME_DIR/api_key"

if tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
  # Already running (systemd restart with the server still alive under a
  # surviving cgroup) — idempotent no-op, matches Type=forking semantics.
  exit 0
fi

if [ ! -r "$CRED_FILE" ]; then
  echo "claude-tmux-start: no credential file at $CRED_FILE — did the fetch ExecStartPre run?" >&2
  exit 1
fi

tmux -L "$SOCKET" new-session -d -s "$SESSION" -n main
tmux -L "$SOCKET" send-keys -t "$SESSION" \
  "export ANTHROPIC_API_KEY=\"\$(cat '$CRED_FILE' 2>/dev/null)\"; rm -f '$CRED_FILE'; exec claude" Enter
