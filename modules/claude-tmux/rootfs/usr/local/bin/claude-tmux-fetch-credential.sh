#!/bin/sh
# claude-tmux-fetch-credential.sh — fetches the Claude Code CLI's Anthropic
# API key from the platform's Vault-backed node_api and stages it for the
# tmux session to consume exactly once.
#
# Runs as root (systemd ExecStartPre=+...) because only root can read the
# on-node agent's mTLS private key. Writes the plaintext to
# $RUNTIME_DIRECTORY/api_key, mode 0600, owned by the unprivileged session
# user — never echoed, never logged, never baked into this image.
#
# Platform-URL + PKI-directory resolution mirrors the Go agent's own
# identity resolver (agent/internal/identity/*.go), read-only, in the same
# priority order: explicit env override -> kernel cmdline -> qemu fw_cfg ->
# /run/powernode/identity.cfg (cidata/cicustom, the Go LocalIdentityStrategy
# path) -> /boot/identity.cfg -> /etc/identity.cfg. Cloud-provider metadata
# strategies (AWS/GCP/Azure/DO) are NOT replicated here — on those providers,
# set the credential's instance manually or extend this script's resolution
# chain.
#
# POWERNODE_PKI_DIR / POWERNODE_PLATFORM_URL are the explicit head of that
# chain. Neither unit sets them, so on a real node resolution always falls
# through to the on-disk sources below; they exist so the exit-code
# taxonomy can be exercised off an enrolled node (the on-node PKI dir is
# 0700 root-only and unreadable even to the session user). See
# tests/credential-fetch/test-fetch-credential-exit-codes.sh.
#
# EXIT CODES — the caller units branch on these, so they are contract:
#   0   credential staged at $RUNTIME_DIRECTORY/api_key
#   78  EX_CONFIG: no credential is configured for this instance (HTTP
#       404). This is a DESIGNED steady state, not a fault — the
#       dev_cell_account_provider_credential_fallback SiteSetting defaults
#       OFF so an idle cell cannot burn API credits (inc21, 2026-07-10).
#       Both consuming units carry RestartPreventExitStatus=78 so this
#       fails ONCE and stays put instead of crash-looping the control
#       plane. Re-arm with `systemctl start` after setting a credential.
#   1   every genuinely transient fault (unenrolled, unresolvable platform
#       URL, network/mTLS error, non-200/404 HTTP, malformed response) —
#       still retried by Restart=on-failure.
# 78 sits outside every status curl (converted to 1 by its own handler
# below) or jq (0,1,2,3,5) can produce, so no shelled-out tool can forge it.
set -eu

RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/claude-tmux}"
CRED_USER="${CLAUDE_TMUX_USER:-pnadmin}"
OUT="$RUNTIME_DIR/api_key"

log() { echo "claude-tmux-fetch-credential: $*" >&2; }

# --- Resolve the on-node agent's PKI directory ------------------------
if [ -n "${POWERNODE_PKI_DIR:-}" ] && [ -f "$POWERNODE_PKI_DIR/node.crt" ]; then
  PKI_DIR="$POWERNODE_PKI_DIR"
elif [ -f /persist/var/lib/powernode/pki/node.crt ]; then
  PKI_DIR=/persist/var/lib/powernode/pki
elif [ -f /var/lib/powernode/pki/node.crt ]; then
  PKI_DIR=/var/lib/powernode/pki
else
  log "no agent PKI material found (instance not enrolled yet) — refusing to start without a credential"
  exit 1
fi

# --- Resolve the platform base URL (same priority order as the agent) -
PLATFORM_URL="${POWERNODE_PLATFORM_URL:-}"

if [ -z "$PLATFORM_URL" ] && [ -r /proc/cmdline ]; then
  PLATFORM_URL=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^powernode\.platform_url=//p' | head -n1)
fi

if [ -z "$PLATFORM_URL" ] && [ -r /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/platform_url/raw ]; then
  PLATFORM_URL=$(cat /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/platform_url/raw)
fi

# cidata/cicustom (NoCloud) enrollment stages identity here — the same path
# the Go agent's LocalIdentityStrategy reads. Checked before the legacy
# /boot + /etc locations so a cidata-enrolled node resolves its platform URL.
if [ -z "$PLATFORM_URL" ] && [ -r /run/powernode/identity.cfg ]; then
  PLATFORM_URL=$(sed -n 's/^SERVER=//p' /run/powernode/identity.cfg | head -n1)
fi

if [ -z "$PLATFORM_URL" ] && [ -r /boot/identity.cfg ]; then
  PLATFORM_URL=$(sed -n 's/^SERVER=//p' /boot/identity.cfg | head -n1)
fi

if [ -z "$PLATFORM_URL" ] && [ -r /etc/identity.cfg ]; then
  PLATFORM_URL=$(sed -n 's/^SERVER=//p' /etc/identity.cfg | head -n1)
fi

if [ -z "$PLATFORM_URL" ]; then
  log "could not resolve platform URL from cmdline/fw_cfg/identity.cfg — refusing to start"
  exit 1
fi
PLATFORM_URL=${PLATFORM_URL%/}

mkdir -p "$RUNTIME_DIR"
RESPONSE="$RUNTIME_DIR/.credential-response.json"
rm -f "$RESPONSE" "$OUT"

HTTP_CODE=$(curl -sS -o "$RESPONSE" -w '%{http_code}' \
  --cert "$PKI_DIR/node.crt" --key "$PKI_DIR/node.key" --cacert "$PKI_DIR/ca-bundle.crt" \
  "$PLATFORM_URL/api/v1/system/node_api/config/claude_code_credential") || {
  log "credential fetch request failed (network/mTLS error)"
  exit 1
}

if [ "$HTTP_CODE" = "404" ]; then
  # EX_CONFIG, NOT a generic failure: an instance with no credential is a
  # supported, deliberate configuration (see the exit-code contract in this
  # script's header). Restarting cannot fix it — only an operator can — so
  # the units suppress the restart on this code rather than looping a
  # handshake against the control plane every RestartSec forever.
  log "no Claude Code credential configured for this instance yet (HTTP 404) — an operator must set one, then: systemctl start <this unit>"
  rm -f "$RESPONSE"
  exit 78
fi

if [ "$HTTP_CODE" != "200" ]; then
  log "credential fetch returned HTTP $HTTP_CODE"
  rm -f "$RESPONSE"
  exit 1
fi

API_KEY=$(jq -r '.data.api_key // empty' "$RESPONSE" 2>/dev/null)
rm -f "$RESPONSE"

if [ -z "$API_KEY" ]; then
  log "response had no api_key field"
  exit 1
fi

umask 077
printf '%s' "$API_KEY" > "$OUT"
chown "$CRED_USER:$CRED_USER" "$OUT" 2>/dev/null || true
chmod 600 "$OUT"
unset API_KEY

log "credential staged for $CRED_USER at $OUT"
