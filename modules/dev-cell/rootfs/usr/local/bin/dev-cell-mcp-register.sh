#!/bin/bash
# dev-cell-mcp-register.sh — register the "powernode" MCP server in the
# INTERACTIVE operator's Claude Code config (pnadmin, user scope) so a dev-cell
# ships with MCP-first tooling pre-wired instead of configured by hand.
#
# Scope of this script (what it is and is NOT for):
#   - The autonomous dev-loop (dev-cell-executor.sh) injects the SAME server
#     inline via `--mcp-config` + `--strict-mcp-config`, which makes headless
#     `claude` ignore user/project config entirely — so the loop does not need
#     and is unaffected by this registration.
#   - The interactive session does the opposite: claude-tmux-start.sh launches a
#     plain `exec claude`, which DOES read ~/.claude.json. That session (and any
#     manual `claude` an operator runs over SSH as pnadmin) is what this wires up.
#
# The entry points at the LOCAL dev-cell-mcp-proxy (a plain-HTTP localhost
# listener). The proxy — NOT this config — holds the node's mTLS client cert and
# forwards to the platform's real /mcp endpoint (ops-hub). No secret is written
# here; the URL is loopback-only.
#
# Runs as pnadmin (User= in the unit) AFTER home-pnadmin.mount, so it writes the
# durable /persist-backed /home/pnadmin/.claude.json, not the pre-mount tmpfs
# home that the bind would later shadow.
#
# Idempotent + self-healing: remove-then-add converges the entry to the correct
# URL even if a prior boot wrote a stale bind/port. `claude mcp add` performs no
# network probe, so this does not require the proxy to be listening yet.
set -euo pipefail

BIND="${DEV_CELL_MCP_PROXY_BIND:-127.0.0.1}"
PORT="${DEV_CELL_MCP_PROXY_PORT:-18443}"
URL="http://${BIND}:${PORT}/mcp"

# `claude` comes from the claude-tmux module — skip cleanly if it isn't
# co-assigned on this instance's template (matches dev-cell-executor.service's
# own ConditionPathExists=/usr/bin/claude fail-closed posture; the unit also
# guards on it, this is belt-and-suspenders for a manual invocation).
if ! command -v claude >/dev/null 2>&1; then
  echo "dev-cell-mcp-register: claude CLI not present (claude-tmux not assigned?) — skipping" >&2
  exit 0
fi

# Converge to the correct entry. remove is best-effort (absent on first boot).
claude mcp remove -s user powernode >/dev/null 2>&1 || true
claude mcp add --transport http -s user powernode "$URL"

echo "dev-cell-mcp-register: registered powernode MCP (user scope, pnadmin) -> $URL"
