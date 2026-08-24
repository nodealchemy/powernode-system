#!/bin/sh
# claude-tmux-start.sh — starts (or, on a systemd restart, no-ops into) the
# managed "claude-code" tmux session and launches the Claude Code CLI
# inside it, consuming whichever credential shape the fetch script staged:
#
#   $RUNTIME_DIR/api_key     — Anthropic API key: the pane exports it as
#       ANTHROPIC_API_KEY and deletes the staged file (original behaviour,
#       unchanged).
#   $RUNTIME_DIR/oauth_ready — OAuth (Claude subscription) marker: the
#       credential lives at the session user's ~/.claude/.credentials.json,
#       which Claude Code reads (and REWRITES on every token refresh)
#       itself. The pane MUST NOT export ANTHROPIC_API_KEY (an env key
#       overrides the OAuth login) and MUST NOT delete the file — it is
#       the node-authoritative credential, not a one-shot handoff.
#
# Runs as the unprivileged session user (systemd User=/Group=). Dedicated
# tmux socket (-L claude-tmux) so this systemd-managed server never
# collides with the operator's own ad-hoc `tmux` sessions.
#
# The api_key credential is deliberately NOT passed as a tmux/systemd argv
# (would leak into `ps`/`/proc/<pid>/cmdline` for any local user) — the
# pane's own shell reads-then-deletes the runtime file, so the secret only
# ever exists in that shell's environment table, never in a process
# listing. The oauth path never touches a shell variable or argv at all.
set -eu

SOCKET=claude-tmux
SESSION=claude-code
RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/claude-tmux}"
CRED_FILE="$RUNTIME_DIR/api_key"
OAUTH_MARKER="$RUNTIME_DIR/oauth_ready"

if tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
  # Already running (systemd restart with the server still alive under a
  # surviving cgroup) — idempotent no-op, matches Type=forking semantics.
  exit 0
fi

if [ -r "$CRED_FILE" ]; then
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -n main
  tmux -L "$SOCKET" send-keys -t "$SESSION" \
    "export ANTHROPIC_API_KEY=\"\$(cat '$CRED_FILE' 2>/dev/null)\"; rm -f '$CRED_FILE'; exec claude" Enter
elif [ -e "$OAUTH_MARKER" ]; then
  # OAuth: claude finds ~/.claude/.credentials.json on its own. No env
  # export, no deletion — see the header.
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -n main
  tmux -L "$SOCKET" send-keys -t "$SESSION" "exec claude" Enter
else
  echo "claude-tmux-start: nothing staged at $CRED_FILE or $OAUTH_MARKER — did the credential unit run?" >&2
  exit 1
fi
