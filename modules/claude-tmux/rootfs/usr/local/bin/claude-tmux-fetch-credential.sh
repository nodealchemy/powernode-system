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
# priority order: kernel cmdline -> qemu fw_cfg -> /boot/identity.cfg ->
# /etc/identity.cfg. Cloud-provider metadata strategies (AWS/GCP/Azure/DO)
# are NOT replicated here — on those providers, set the credential's
# instance manually or extend this script's resolution chain.
set -eu

RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/claude-tmux}"
CRED_USER="${CLAUDE_TMUX_USER:-pnadmin}"
OUT="$RUNTIME_DIR/api_key"

log() { echo "claude-tmux-fetch-credential: $*" >&2; }

# --- Resolve the on-node agent's PKI directory ------------------------
if [ -f /persist/var/lib/powernode/pki/node.crt ]; then
  PKI_DIR=/persist/var/lib/powernode/pki
elif [ -f /var/lib/powernode/pki/node.crt ]; then
  PKI_DIR=/var/lib/powernode/pki
else
  log "no agent PKI material found (instance not enrolled yet) — refusing to start without a credential"
  exit 1
fi

# --- Resolve the platform base URL (same priority order as the agent) -
PLATFORM_URL=""

if [ -r /proc/cmdline ]; then
  PLATFORM_URL=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^powernode\.platform_url=//p' | head -n1)
fi

if [ -z "$PLATFORM_URL" ] && [ -r /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/platform_url/raw ]; then
  PLATFORM_URL=$(cat /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/platform_url/raw)
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
  log "no Claude Code credential configured for this instance yet (HTTP 404) — an operator must set one"
  rm -f "$RESPONSE"
  exit 1
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
