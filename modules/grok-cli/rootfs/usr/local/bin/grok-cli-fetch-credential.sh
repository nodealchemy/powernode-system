#!/bin/sh
# grok-cli-fetch-credential.sh — fetches this instance's xAI API key from
# the platform's Vault-backed node_api and stages it for the Grok CLI.
#
# Runs as root (systemd ExecStart of the credential oneshot) because only
# root can read the on-node agent's mTLS private key. The key is never
# echoed, never logged, and never baked into this image. It goes jq -> file
# directly: never through a shell variable that could reach `ps`, a trace,
# or an error message.
#
# Ported from claude-tmux-fetch-credential.sh with every OAuth branch
# removed — an xAI credential is api_key ONLY. Consequently there is no
# "node-authoritative local credential" fallback here either: that fallback
# exists because Claude Code ROTATES ITS OWN tokens in place, making the
# platform's copy stale by design. Nothing rotates an xAI API key on the
# node, so the platform stays authoritative and a fetch failure is simply a
# fetch failure.
#
# Platform-URL + PKI-directory resolution mirrors the Go agent's own
# identity resolver (agent/internal/identity/*.go), read-only, in the same
# priority order: explicit env override -> kernel cmdline -> qemu fw_cfg ->
# /run/powernode/identity.cfg (cidata/cicustom, the Go LocalIdentityStrategy
# path) -> /boot/identity.cfg -> /etc/identity.cfg. Cloud-provider metadata
# strategies (AWS/GCP/Azure/DO) are NOT replicated here — on those providers
# set the credential's instance manually or extend this resolution chain.
#
# POWERNODE_PKI_DIR / POWERNODE_PLATFORM_URL are the explicit head of that
# chain. No unit sets them, so on a real node resolution always falls
# through to the on-disk sources below; they exist so the exit-code taxonomy
# can be exercised off an enrolled node (the on-node PKI dir is 0700
# root-only).
#
# EXIT CODES — the caller unit branches on these, so they are contract:
#   0   credential staged at $RUNTIME_DIRECTORY/api_key (0600, owned by
#       $GROK_CLI_USER). /etc/profile.d/grok-cli.sh exports it as
#       XAI_API_KEY into that user's login shells.
#   78  EX_CONFIG: no xAI credential is configured for this instance
#       (HTTP 404). This is a DESIGNED steady state, not a fault — the
#       account-provider fallback SiteSetting defaults OFF so an idle cell
#       cannot burn API credits. The unit maps 78 to success
#       (SuccessExitStatus=78) rather than looping a handshake against the
#       control plane every RestartSec forever. Re-arm with
#       `systemctl start <unit>` after setting a credential.
#   1   every genuinely transient fault (unenrolled, unresolvable platform
#       URL, network/mTLS error, non-200/404 HTTP, malformed response) —
#       still retried by Restart=on-failure.
# 78 sits outside every status curl (converted to 1 by its own handler
# below) or jq (0,1,2,3,5) can produce, so no shelled-out tool can forge it.
set -eu

RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/grok-cli}"
CRED_USER="${GROK_CLI_USER:-pnadmin}"
OUT="$RUNTIME_DIR/api_key"

log() { echo "grok-cli-fetch-credential: $*" >&2; }

# --- Resolve the on-node agent's PKI directory ------------------------
if [ -n "${POWERNODE_PKI_DIR:-}" ] && [ -f "$POWERNODE_PKI_DIR/node.crt" ]; then
  PKI_DIR="$POWERNODE_PKI_DIR"
elif [ -f /persist/var/lib/powernode/pki/node.crt ]; then
  PKI_DIR=/persist/var/lib/powernode/pki
elif [ -f /var/lib/powernode/pki/node.crt ]; then
  PKI_DIR=/var/lib/powernode/pki
else
  log "no agent PKI material found (instance not enrolled yet) — cannot fetch a credential"
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
  log "could not resolve platform URL from cmdline/fw_cfg/identity.cfg — cannot fetch a credential"
  exit 1
fi
PLATFORM_URL=${PLATFORM_URL%/}

# Everything staged from here on is secret-adjacent: response body and
# staged key alike. Tighten BEFORE the first byte is written (the curl -o
# below included), not just before the final chmod.
umask 077

mkdir -p "$RUNTIME_DIR"

# Hand the runtime directory itself to the session user.
#
# THIS IS LOAD-BEARING, and its absence is silent. systemd's
# RuntimeDirectory= creates /run/grok-cli as root:root 0700, and a 0700
# directory cannot be TRAVERSED by anyone else — so /etc/profile.d/grok-cli.sh,
# running as $CRED_USER, would fail to read a key it owns, with no error
# anywhere: the shim is a deliberate silent no-op on an unreadable path, so
# `grok` would simply act unauthenticated.
#
# claude-tmux never hits this because its SESSION unit re-declares the same
# RuntimeDirectory= with User=pnadmin, which makes systemd re-apply ownership.
# This module has no second unit (by design — see the manifest), so the chown
# has to happen here.
#
# 0700 is KEPT rather than widened to 0755: after this chown only $CRED_USER
# and root can traverse the directory at all, so no other unprivileged user
# on the node can even enumerate what is staged.
chown "$CRED_USER:$CRED_USER" "$RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$RUNTIME_DIR"

RESPONSE="$RUNTIME_DIR/.credential-response.json"

# No exit path may leave the plaintext response — or a half-written staging
# temp — behind. set -e aborts mid-branch on any tool failure, so per-branch
# rm lines alone cannot guarantee cleanup.
trap 'rm -f "$RESPONSE" "$OUT.tmp"' EXIT

# Clear any previously staged key first, so a credential REVOKED on the
# platform side does not leave the old one readable until the next success.
rm -f "$RESPONSE" "$OUT"

HTTP_CODE=$(curl -sS -o "$RESPONSE" -w '%{http_code}' \
  --cert "$PKI_DIR/node.crt" --key "$PKI_DIR/node.key" --cacert "$PKI_DIR/ca-bundle.crt" \
  "$PLATFORM_URL/api/v1/system/node_api/config/ai_cli_credential?provider_type=grok") || {
  log "credential fetch request failed (network/mTLS error)"
  exit 1
}

if [ "$HTTP_CODE" = "404" ]; then
  # EX_CONFIG, NOT a generic failure: an instance with no credential is a
  # supported, deliberate configuration (see the exit-code contract in this
  # script's header). Restarting cannot fix it — only an operator can.
  log "no xAI credential configured for this instance yet (HTTP 404) — an operator must set one, then: systemctl start <this unit>"
  exit 78
fi

if [ "$HTTP_CODE" != "200" ]; then
  log "credential fetch returned HTTP $HTTP_CODE"
  exit 1
fi

# The platform DECLARES the credential kind — never inferred from which
# fields happen to be present. Absent field = api_key, the only kind an xAI
# credential has; anything else is a platform/module version skew and is a
# hard failure rather than a silent mis-stage.
CRED_TYPE=$(jq -r '.data.credential_type // "api_key"' "$RESPONSE" 2>/dev/null || echo api_key)
if [ "$CRED_TYPE" != "api_key" ]; then
  log "response declared unsupported credential_type=$CRED_TYPE for provider grok"
  exit 1
fi

if ! jq -e '.data.api_key | strings | length > 0' "$RESPONSE" >/dev/null 2>&1; then
  log "response had no usable api_key field"
  exit 1
fi

# jq -> file directly. The key never becomes a shell variable, an argv
# element, or a here-doc — any of which could surface in ps, a trace, or an
# error message (CryptoMaterialSafety: no key args in logs).
jq -j '.data.api_key' "$RESPONSE" > "$OUT.tmp"
mv -f "$OUT.tmp" "$OUT"
chown "$CRED_USER:$CRED_USER" "$OUT" 2>/dev/null || true
chmod 600 "$OUT"

log "credential staged for $CRED_USER at $OUT"
