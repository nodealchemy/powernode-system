#!/bin/sh
# gitea-act-runner-register.sh — live-mints a Gitea Actions runner
# registration token from the platform's Vault-backed node_api and stages
# it for gitea-act-runner-start.sh to consume exactly once per service
# start.
#
# Runs as root (systemd ExecStartPre=+...) because only root can read the
# on-node agent's mTLS private key. The token is written ONLY to
# $RUNTIME_DIRECTORY/register_input, mode 0600, owned by the unprivileged
# service user (pnrunner) — never echoed, never logged, never baked into
# this module's image. set -eu deliberately, NEVER set -x (a trace would
# print the token to the unit's journal output).
#
# Idempotent: if a prior successful `act_runner register` already produced
# a .runner file in $STATE_DIRECTORY, this exits 0 immediately without
# minting (or even requesting) a new token — a live-minted token is
# multi-use only by accident of the org-scope default (see the platform
# endpoint's docstring), so this script still avoids burning one it
# doesn't need.
#
# Platform-URL + PKI-directory resolution mirrors claude-tmux's own
# claude-tmux-fetch-credential.sh (itself a read-only shell re-derivation of
# the Go agent's own identity resolver, agent/internal/identity/*.go), in
# the same priority order: kernel cmdline -> qemu fw_cfg -> /boot/
# identity.cfg -> /etc/identity.cfg. Same known gap as that script:
# cloud-provider metadata strategies (AWS/GCP/Azure/DO) are not replicated
# here.
set -eu

RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/gitea-act-runner}"
STATE_DIR="${STATE_DIRECTORY:-/var/lib/gitea-act-runner}"
RUNNER_USER="${GITEA_ACT_RUNNER_USER:-pnrunner}"
INPUT_OUT="$RUNTIME_DIR/register_input"
FLAGS_OUT="$RUNTIME_DIR/register_flags"

log() { echo "gitea-act-runner-register: $*" >&2; }

# --- Idempotent: already registered once, nothing to mint -------------
if [ -s "$STATE_DIR/.runner" ]; then
  log "already registered ($STATE_DIR/.runner present) — skipping token mint"
  exit 0
fi

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
RESPONSE="$RUNTIME_DIR/.registration-response.json"
rm -f "$RESPONSE" "$INPUT_OUT" "$FLAGS_OUT"

# Belt-and-suspenders umask even though $RUNTIME_DIR is already 0700
# root-owned (RuntimeDirectoryMode=0700) — curl can't hand the response
# back at a more permissive mode.
umask 077
HTTP_CODE=$(curl -sS -o "$RESPONSE" -w '%{http_code}' \
  --cert "$PKI_DIR/node.crt" --key "$PKI_DIR/node.key" --cacert "$PKI_DIR/ca-bundle.crt" \
  "$PLATFORM_URL/api/v1/system/node_api/config/ci_runner_registration") || {
  log "registration token fetch request failed (network/mTLS error)"
  exit 1
}

if [ "$HTTP_CODE" = "403" ]; then
  log "instance not provisioned as a gitea-act-runner (HTTP 403) — module-presence gate on the platform side rejected this instance"
  rm -f "$RESPONSE"
  exit 1
fi

if [ "$HTTP_CODE" = "404" ]; then
  log "no Gitea credential configured for CI runner registration yet (HTTP 404) — an operator must set one"
  rm -f "$RESPONSE"
  exit 1
fi

if [ "$HTTP_CODE" != "200" ]; then
  log "registration token fetch returned HTTP $HTTP_CODE"
  rm -f "$RESPONSE"
  exit 1
fi

jq -e '.data.gitea_instance_url and .data.registration_token and .data.runner_name and (.data.labels | length > 0)' \
  "$RESPONSE" >/dev/null 2>&1 || {
  log "response missing gitea_instance_url/registration_token/runner_name/labels"
  rm -f "$RESPONSE"
  exit 1
}

# act_runner v0.2.13's `register` prompts interactively in exactly this
# order: instance URL, token, runner name, labels (comma-separated). One
# answer per line, fed via STDIN by gitea-act-runner-start.sh — never argv,
# never an env var. The token therefore only ever touches disk here (0600,
# pnrunner-owned, tmpfs) and STDIN of the register process; it is never
# passed as a command-line argument that would leak into `ps`.
jq -r '[.data.gitea_instance_url, .data.registration_token, .data.runner_name, (.data.labels | join(","))] | .[]' \
  "$RESPONSE" > "$INPUT_OUT"

jq -r '.data.ephemeral // false' "$RESPONSE" > "$FLAGS_OUT"

rm -f "$RESPONSE"

chown "$RUNNER_USER:$RUNNER_USER" "$INPUT_OUT" "$FLAGS_OUT" 2>/dev/null || true
chmod 600 "$INPUT_OUT" "$FLAGS_OUT"

# Log names only (runner_name, instance URL host) — never the token. Read
# the two non-secret fields back from the file we just wrote rather than
# re-touching $RESPONSE (already deleted).
RUNNER_NAME=$(sed -n '3p' "$INPUT_OUT")
log "registration token staged for $RUNNER_USER (runner: $RUNNER_NAME)"
