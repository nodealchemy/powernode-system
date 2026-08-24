#!/bin/sh
# claude-tmux-fetch-credential.sh — fetches the Claude Code CLI's
# credential from the platform's Vault-backed node_api and stages it for
# the tmux session.
#
# Runs as root (systemd ExecStart of the credential oneshot) because only
# root can read the on-node agent's mTLS private key. Never echoed, never
# logged, never baked into this image. The response DECLARES its kind
# (data.credential_type); this script branches on that declaration:
#
#   "api_key" (default) — writes the plaintext to $RUNTIME_DIRECTORY/api_key,
#       mode 0600, owned by the unprivileged session user; the session pane
#       reads-then-deletes it into ANTHROPIC_API_KEY. Unchanged behaviour.
#
#   "oauth" (Claude subscription) — installs data.oauth_credentials
#       VERBATIM as the session user's ~/.claude/.credentials.json (0600)
#       and stages an empty $RUNTIME_DIRECTORY/oauth_ready marker for the
#       session unit's condition gate. SEED-ONCE / NODE-AUTHORITATIVE:
#       Claude Code rotates BOTH tokens in place when it refreshes, so the
#       platform's Vault copy goes stale by design — if a usable local
#       credential already exists (a parseable file whose
#       .claudeAiOauth.refreshToken is a non-empty string) this script
#       MUST NOT touch it: overwriting a locally-refreshed file with the
#       stale seed silently kills the session weeks later. The seed is
#       installed only when no usable local credential exists (fresh
#       node, wiped home, or corrupt file).
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
# POWERNODE_PKI_DIR / POWERNODE_PLATFORM_URL / CLAUDE_TMUX_CRED_HOME are
# the explicit head of that chain. No unit sets them, so on a real node
# resolution always falls through to the on-disk sources below (and the
# oauth install target to the session user's getent home); they exist so
# the exit-code taxonomy can be exercised off an enrolled node (the
# on-node PKI dir is 0700 root-only and unreadable even to the session
# user, and the suite must never touch the invoker's real
# ~/.claude/.credentials.json). See
# tests/credential-fetch/test-fetch-credential-exit-codes.sh.
#
# EXIT CODES — the caller units branch on these, so they are contract:
#   0   credential staged: $RUNTIME_DIRECTORY/api_key (api_key kind), or
#       the installed/preserved ~/.claude/.credentials.json plus the
#       $RUNTIME_DIRECTORY/oauth_ready marker (oauth kind)
#   78  EX_CONFIG: no credential is configured for this instance (HTTP
#       404) AND no usable local OAuth credential exists. (With a usable
#       local credential, 404 — and every transient fault — degrades to
#       exit 0 with the oauth_ready marker staged: the node is
#       authoritative, so neither a control-plane outage nor a deleted
#       platform row may stop a session the platform cannot help anyway.
#       Revoking a seeded node means removing its local
#       ~/.claude/.credentials.json, not deleting the platform row.)
#       This is a DESIGNED steady state, not a fault — the
#       dev_cell_account_provider_credential_fallback SiteSetting defaults
#       OFF so an idle cell cannot burn API credits (inc21, 2026-07-10).
#       The credential unit maps 78 to success (SuccessExitStatus=78 —
#       NOT RestartPreventExitStatus, which is inert for this shape and
#       asserted ABSENT by the test harness) and the session unit's
#       ConditionPathExists gate then skips cleanly. Re-arm with
#       `systemctl start` after setting a credential.
#       KNOWN EDGES of the continuity fallback (deliberate, self-healing;
#       it keys on the LOCAL file because the platform's declared kind is
#       unknowable without a 200): (1) after an oauth->api_key flip on
#       the platform, a transient fault starts the session on the
#       leftover subscription login until the next successful fetch
#       re-stages the api_key; (2) a leftover usable local OAuth file on
#       an api_key-kind instance makes a transient fault exit 0 staging
#       only oauth_ready — claude-tmux's OR gate then starts on that
#       login, while dev-cell's api_key-only gate skips its executor
#       until the next successful fetch. Future hardening: gate the
#       fallback on the last-known platform kind.
#   1   every genuinely transient fault (unenrolled, unresolvable platform
#       URL, network/mTLS error, non-200/404 HTTP, malformed response) —
#       still retried by Restart=on-failure.
# 78 sits outside every status curl (converted to 1 by its own handler
# below) or jq (0,1,2,3,5) can produce, so no shelled-out tool can forge it.
set -eu

RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/claude-tmux}"
CRED_USER="${CLAUDE_TMUX_USER:-pnadmin}"
OUT="$RUNTIME_DIR/api_key"
OAUTH_MARKER="$RUNTIME_DIR/oauth_ready"

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

# Everything staged from here on is secret-adjacent: response body, staged
# key, installed credentials file. Tighten BEFORE the first byte is
# written (the curl -o below included), not just before the final copy.
umask 077

mkdir -p "$RUNTIME_DIR"
RESPONSE="$RUNTIME_DIR/.credential-response.json"

# Where an OAuth credential would live for $CRED_USER, and whether a
# usable one is already present (seed-once: the node owns it then).
# Resolved up front because the FAILURE branches below also need it — a
# usable local credential must keep the session startable when the
# platform cannot answer. "Usable" = parseable JSON whose
# .claudeAiOauth.refreshToken is a non-empty string.
CRED_HOME="${CLAUDE_TMUX_CRED_HOME:-$(getent passwd "$CRED_USER" | cut -d: -f6 || true)}"
CRED_JSON=""
LOCAL_OAUTH_USABLE=0
if [ -n "$CRED_HOME" ] && [ -d "$CRED_HOME" ]; then
  CRED_JSON="$CRED_HOME/.claude/.credentials.json"
  if [ -r "$CRED_JSON" ] && jq -e '.claudeAiOauth.refreshToken | strings | length > 0' "$CRED_JSON" >/dev/null 2>&1; then
    LOCAL_OAUTH_USABLE=1
  fi
fi

# Gate marker for the session unit (ConditionPathExists=|...). Contains
# nothing — the credential itself lives only in the staged/installed file.
stage_oauth_marker() {
  : > "$OAUTH_MARKER"
  chown "$CRED_USER:$CRED_USER" "$OAUTH_MARKER" 2>/dev/null || true
  chmod 600 "$OAUTH_MARKER"
}

# No exit path may leave the plaintext response (or a half-written
# install temp) behind — set -e aborts mid-branch on any tool failure,
# so per-branch rm lines alone cannot guarantee cleanup.
trap 'rm -f "$RESPONSE"; if [ -n "$CRED_JSON" ]; then rm -f "$CRED_JSON.tmp"; fi' EXIT

# Clear BOTH staged shapes so a kind change on the platform side never
# leaves a stale gate file from the other kind behind.
rm -f "$RESPONSE" "$OUT" "$OAUTH_MARKER"

HTTP_CODE=$(curl -sS -o "$RESPONSE" -w '%{http_code}' \
  --cert "$PKI_DIR/node.crt" --key "$PKI_DIR/node.key" --cacert "$PKI_DIR/ca-bundle.crt" \
  "$PLATFORM_URL/api/v1/system/node_api/config/claude_code_credential") || {
  if [ "$LOCAL_OAUTH_USABLE" = 1 ]; then
    log "credential fetch request failed (network/mTLS error) — usable local OAuth credential exists, node-authoritative: session may start"
    stage_oauth_marker
    exit 0
  fi
  log "credential fetch request failed (network/mTLS error)"
  exit 1
}

if [ "$HTTP_CODE" = "404" ]; then
  if [ "$LOCAL_OAUTH_USABLE" = 1 ]; then
    # Deleting the platform row does NOT revoke a seeded node — the local
    # credential is authoritative (see the exit-code contract above).
    # Revocation happens on the node (remove ~/.claude/.credentials.json)
    # or at Anthropic, never by starving the fetch.
    log "no platform credential (HTTP 404) but a usable local OAuth credential exists — node-authoritative: session may start"
    stage_oauth_marker
    exit 0
  fi
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
  if [ "$LOCAL_OAUTH_USABLE" = 1 ]; then
    log "credential fetch returned HTTP $HTTP_CODE — usable local OAuth credential exists, node-authoritative: session may start"
    stage_oauth_marker
    exit 0
  fi
  log "credential fetch returned HTTP $HTTP_CODE"
  rm -f "$RESPONSE"
  exit 1
fi

# The platform DECLARES the credential kind — never inferred from which
# fields happen to be present. Absent field (pre-OAuth platform) = api_key.
CRED_TYPE=$(jq -r '.data.credential_type // "api_key"' "$RESPONSE" 2>/dev/null || echo api_key)

if [ "$CRED_TYPE" = "oauth" ]; then
  # ---- OAuth (Claude subscription): seed-once install ----------------
  if [ -z "$CRED_JSON" ]; then
    # No resolvable EXISTING home for $CRED_USER. Refuse rather than
    # mkdir -p the chain — under this script's root + umask 077 that
    # would manufacture a root-owned 0700 home the session user cannot
    # even traverse (prior fleet home-ownership incident class).
    log "no existing home directory for $CRED_USER — cannot install the OAuth credential"
    rm -f "$RESPONSE"
    exit 1
  fi
  CLAUDE_DIR="$CRED_HOME/.claude"

  if [ "$LOCAL_OAUTH_USABLE" = 1 ]; then
    # SEED-ONCE: the node owns a usable credential — Claude Code has been
    # (or will be) rotating its tokens in place, so the Vault copy is a
    # stale snapshot by design. Overwriting here would install a used
    # refresh token and silently kill the session. Leave it untouched.
    log "usable local OAuth credential already present — node-authoritative, leaving it untouched (seed-once)"
  else
    # No usable local credential (fresh node, wiped home, or corrupt
    # file): install the Vault seed. The blob goes jq->file directly —
    # never through a shell variable or argv.
    if ! jq -e '.data.oauth_credentials.claudeAiOauth.refreshToken | strings | length > 0' "$RESPONSE" >/dev/null 2>&1; then
      log "response declared credential_type=oauth but carried no usable oauth_credentials"
      rm -f "$RESPONSE"
      exit 1
    fi
    if [ ! -d "$CLAUDE_DIR" ]; then
      # Only chown/chmod a directory THIS script created — never tighten
      # or re-own a pre-existing ~/.claude the user set up themselves.
      mkdir -p "$CLAUDE_DIR"
      chown "$CRED_USER:$CRED_USER" "$CLAUDE_DIR" 2>/dev/null || true
      chmod 700 "$CLAUDE_DIR"
    fi
    jq -c '.data.oauth_credentials' "$RESPONSE" > "$CRED_JSON.tmp"
    mv -f "$CRED_JSON.tmp" "$CRED_JSON"
    chown "$CRED_USER:$CRED_USER" "$CRED_JSON" 2>/dev/null || true
    chmod 600 "$CRED_JSON"
    log "OAuth credential seeded at $CRED_JSON for $CRED_USER (the node now owns refresh; the platform copy is a bootstrap seed)"
  fi
  rm -f "$RESPONSE"

  stage_oauth_marker
  log "oauth marker staged at $OAUTH_MARKER"
  exit 0
fi

API_KEY=$(jq -r '.data.api_key // empty' "$RESPONSE" 2>/dev/null || true)
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
