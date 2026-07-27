#!/bin/sh
# dev-cell-bootstrap.sh — fetches the dev-cell's mTLS bootstrap bundle (an
# MCP url + a per-repo Gitea SSH deploy key) from the platform's
# Vault-backed node_api and stages it — plus a copy of the node's OWN mTLS
# identity — for dev-cell-provision.sh, dev-cell-mcp-proxy.js, and
# dev-cell-executor.sh to consume, exactly once per boot (RuntimeDirectory
# is tmpfs, wiped at shutdown — a fresh fetch happens every boot).
#
# PRIVILEGE SEPARATION (CRITICAL, read before touching ownership/perms
# below): everything this script stages stays ROOT-OWNED, mode 0600/0644.
# It is NEVER chowned to the unprivileged sandbox user (pnagent) that runs
# headless `claude` + scripts/validate.sh — see dev-cell-executor.sh and
# this module's manifest.yaml description for why. In particular, handing
# pnagent the node's own mTLS key (node.key) would let a compromised
# agent re-call this SAME dev_cell_bootstrap endpoint directly and mint
# itself a FRESH Gitea deploy key, defeating the whole point of keeping
# the deploy key root-only — so node.key is confined exactly as tightly
# as the deploy key is. Only two root-owned processes ever read this
# directory: dev-cell-mcp-proxy.js (node.crt/node.key/ca-bundle.crt +
# mcp_credentials.json, to front /mcp on pnagent's behalf) and
# dev-cell-executor.sh / dev-cell-provision.sh (deploy_key/known_hosts,
# for the clone/push git only root ever performs).
#
# Runs as root (systemd User=root — only root can read the on-node agent's
# mTLS private key). Writes plaintext secrets to $RUNTIME_DIR
# (/run/dev-cell by default), mode 0600 root-owned — never echoed, never
# logged, never baked into this module's image.
#
# SECURITY (mTLS-only contract — no OAuth/token of any kind): the cell
# authenticates to /mcp by presenting the node's own client cert through
# the local proxy (not directly — see dev-cell-mcp-proxy.js), so this
# bundle carries no bearer token to protect there. It authenticates to
# Gitea with a per-repo, read-write SSH deploy key (gitea.private_key
# below) instead of an account-wide PAT — scoped to exactly the one
# source repo dev-cell-provision.sh clones, nothing else.
#
# Platform-URL + PKI-directory resolution mirrors the Go agent's own
# identity resolver (agent/internal/identity/*.go for the enrollment-time
# discovery chain; agent/internal/enroll.ReadPlatformURL for the persisted
# post-enrollment path), in priority order: $PKI_DIR/meta.json (durable,
# written by enroll.Save() at enroll time — what every boot after the first
# actually relies on) -> kernel cmdline -> qemu fw_cfg -> /boot/identity.cfg
# -> /etc/identity.cfg (enrollment-time / cloud-init-style fallbacks, before
# meta.json exists). Known gap, same as claude-tmux-fetch-credential.sh:
# cloud-provider metadata strategies (AWS/GCP/Azure/DO) are not replicated
# here.
set -eu

RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/dev-cell}"
MCP_OUT="$RUNTIME_DIR/mcp_credentials.json"
GITEA_OUT="$RUNTIME_DIR/gitea_credentials.json"
DEPLOY_KEY_OUT="$RUNTIME_DIR/deploy_key"
KNOWN_HOSTS_OUT="$RUNTIME_DIR/known_hosts"

log() { echo "dev-cell-bootstrap: $*" >&2; }

# --- Resolve the on-node agent's PKI directory ------------------------
# $DEV_CELL_PKI_DIR is checked first purely as an explicit override, the
# same shape as $RUNTIME_DIRECTORY above: the unit never sets it, so on a
# real node resolution is byte-identical to the two durable paths below.
# It exists so the retry loop further down can be driven under test
# without a real enrolled identity (anything that can set this unit's
# environment is already root, which is what it takes to read node.key
# anyway).
if [ -n "${DEV_CELL_PKI_DIR:-}" ] && [ -f "${DEV_CELL_PKI_DIR}/node.crt" ]; then
  PKI_DIR="$DEV_CELL_PKI_DIR"
elif [ -f /persist/var/lib/powernode/pki/node.crt ]; then
  PKI_DIR=/persist/var/lib/powernode/pki
elif [ -f /var/lib/powernode/pki/node.crt ]; then
  PKI_DIR=/var/lib/powernode/pki
else
  log "no agent PKI material found (instance not enrolled yet) — refusing to start without a credential"
  exit 1
fi

# --- Resolve the platform base URL --------------------------------------
# $PKI_DIR/meta.json checked FIRST: it's the durable record the Go agent's
# own enroll.Save() writes at enroll time (agent/internal/enroll/storage.go)
# and re-reads on every later boot via ReadPlatformURL — the exact mechanism
# that lets the post-pivot service adopt an already-enrolled identity
# without cmdline/fw_cfg carrying platform_url again. A live in-place boot-
# image upgrade (UpgradeDispatcher/bootupgrade) swaps only the UKI — its
# cmdline is minimal (powernode.boot=1 + image_git_sha for tracking), no
# powernode.platform_url= — so on every boot after the first enrollment,
# cmdline/fw_cfg/identity.cfg are ALL empty and this script refused to start
# (observed: 100+ restart loop on VM9000 after an in-place upgrade). The
# remaining channels stay as the enrollment-time / cloud-init-style fallback
# for a node's very first boot, before meta.json exists.
PLATFORM_URL=""

if [ -r "$PKI_DIR/meta.json" ]; then
  PLATFORM_URL=$(sed -n 's/.*"platform_url":"\([^"]*\)".*/\1/p' "$PKI_DIR/meta.json" | head -n1)
fi

if [ -z "$PLATFORM_URL" ] && [ -r /proc/cmdline ]; then
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
  log "could not resolve platform URL from meta.json/cmdline/fw_cfg/identity.cfg — refusing to start"
  exit 1
fi
PLATFORM_URL=${PLATFORM_URL%/}

# RuntimeDirectory is created by systemd (RuntimeDirectory=dev-cell in the
# unit) already root:root 0700 because this unit's User=root — that is
# EXACTLY the confinement wanted here, so unlike the pre-privilege-
# separation version of this script, nothing below ever chowns it to
# anyone else.
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

RESPONSE="$RUNTIME_DIR/.bootstrap-response.json"
rm -f "$RESPONSE" "$MCP_OUT" "$GITEA_OUT" "$DEPLOY_KEY_OUT" "$KNOWN_HOSTS_OUT"

# The raw response carries the deploy-key PRIVATE key (gitea.private_key)
# before it's split into its own file below — belt-and-suspenders umask
# even though $RUNTIME_DIR is already 0700 root-owned, so curl can't hand
# it back at the default, more permissive mode.
umask 077

# BOOT RACE (why this is a retry loop and not a single curl): this unit is
# ordered After=network-online.target, which guarantees a configured link and
# a route — it says NOTHING about systemd-resolved being able to answer. On a
# pivot boot the switch-root re-execs PID1 and restarts resolved, and this
# unit starts in that same second, so the very first fetch can land squarely
# in the window where DNS is simply down (observed 2026-07-27 14:36:49 on
# ops-hub-dev-cell-1784413717: "curl: (6) Could not resolve host").
#
# Restart=on-failure DOES recover this unit ~15s later — but that is far too
# late for anything ordered on it. A start job cancelled because a Requires=
# dependency failed is NEVER re-queued when that dependency later succeeds,
# so dev-cell-mcp-proxy.service stayed dead for the rest of that boot (nothing
# listening on 127.0.0.1:18443, MCP unreachable from the cell) even though
# this unit went on to succeed 17s later. Absorbing the transient HERE, before
# the unit can ever enter `failed`, is what keeps the dependents alive.
#
# Retried: transport failures (DNS/connect/TLS) and 5xx — i.e. "the network or
# the far end isn't up yet", both of which self-resolve. NOT retried: 404 ("no
# bundle provisioned for this instance yet") and every other 4xx, which are
# definitive operator-facing answers that no amount of waiting changes.
FETCH_ATTEMPTS="${DEV_CELL_BOOTSTRAP_ATTEMPTS:-6}"
FETCH_RETRY_DELAY="${DEV_CELL_BOOTSTRAP_RETRY_DELAY:-5}"

attempt=1
while : ; do
  if HTTP_CODE=$(curl -sS -o "$RESPONSE" -w '%{http_code}' \
    --cert "$PKI_DIR/node.crt" --key "$PKI_DIR/node.key" --cacert "$PKI_DIR/ca-bundle.crt" \
    "$PLATFORM_URL/api/v1/system/node_api/config/dev_cell_bootstrap"); then
    CURL_RC=0
  else
    CURL_RC=$?
    HTTP_CODE=""
  fi

  # A definitive HTTP answer (anything that isn't 5xx) ends the loop and falls
  # through to the per-code handling below — including the 200 success path.
  if [ "$CURL_RC" -eq 0 ]; then
    case "$HTTP_CODE" in
      5??) : ;;
      *) break ;;
    esac
  fi

  if [ "$attempt" -ge "$FETCH_ATTEMPTS" ]; then
    if [ "$CURL_RC" -ne 0 ]; then
      log "bootstrap fetch request failed (network/mTLS error, curl rc=$CURL_RC) after $attempt attempts"
      exit 1
    fi
    break
  fi

  if [ "$CURL_RC" -ne 0 ]; then
    log "bootstrap fetch attempt $attempt/$FETCH_ATTEMPTS failed (network/mTLS error, curl rc=$CURL_RC) — retrying in ${FETCH_RETRY_DELAY}s"
  else
    log "bootstrap fetch attempt $attempt/$FETCH_ATTEMPTS returned HTTP $HTTP_CODE — retrying in ${FETCH_RETRY_DELAY}s"
  fi
  sleep "$FETCH_RETRY_DELAY"
  attempt=$((attempt + 1))
done

if [ "$HTTP_CODE" = "404" ]; then
  log "no dev-cell bootstrap bundle configured for this instance yet (HTTP 404) — an operator must provision one"
  rm -f "$RESPONSE"
  exit 1
fi

if [ "$HTTP_CODE" != "200" ]; then
  log "bootstrap fetch returned HTTP $HTTP_CODE"
  rm -f "$RESPONSE"
  exit 1
fi

# Tolerate both a bare {"mcp":..., "gitea":...} body and a render_success
# {"data": {...}} envelope — same defensive shape-tolerance as before.
# known_hosts is intentionally NOT required here: an empty/absent
# known_hosts is a legitimate (if less safe) response the platform can send
# when it has no Gitea host key on record — dev-cell-git-ssh-env.sh is what
# fails closed on that, not this well-formedness check.
jq -e '((.data // .) | .mcp.mcp_url) and ((.data // .) | .gitea.clone_url) and ((.data // .) | .gitea.private_key)' "$RESPONSE" >/dev/null 2>&1 || {
  log "bootstrap response missing mcp.mcp_url / gitea.clone_url / gitea.private_key (checked both a bare body and a .data envelope)"
  rm -f "$RESPONSE"
  exit 1
}

jq '(.data // .).mcp' "$RESPONSE" > "$MCP_OUT"
# private_key and known_hosts are pulled into their OWN raw files below (ssh
# -i / UserKnownHostsFile need real files, not JSON) — del() them here so
# the private key is never duplicated across two on-disk copies.
jq '(.data // .).gitea | del(.private_key) | del(.known_hosts)' "$RESPONSE" > "$GITEA_OUT"
jq -r '(.data // .).gitea.private_key' "$RESPONSE" > "$DEPLOY_KEY_OUT"
# -j, NOT -r: an empty known_hosts ("" — exactly what
# DevCellBootstrapService#known_hosts_for returns when the platform has no
# Gitea host key on record) must land as a truly 0-byte file. `jq -r`
# always appends a trailing newline after the value, which would turn ""
# into a 1-byte file; dev-cell-git-ssh-env.sh's fail-closed check is a
# plain `[ -s known_hosts ]` (non-zero size), so that stray newline would
# silently defeat it — a 1-byte "empty" file would be treated as present.
jq -j '(.data // .).gitea.known_hosts // empty' "$RESPONSE" > "$KNOWN_HOSTS_OUT"
rm -f "$RESPONSE"

chmod 600 "$MCP_OUT" "$GITEA_OUT" "$DEPLOY_KEY_OUT" "$KNOWN_HOSTS_OUT"

# --- Stage a root-only copy of the node's own mTLS identity ---------------
# dev-cell-mcp-proxy.js (root) presents THIS SAME cert to /mcp on pnagent's
# behalf — copied here (rather than pointed at $PKI_DIR directly) purely
# so every dev-cell secret lives in the ONE tmpfs runtime directory with
# the same boot-scoped lifetime, matching every other file this script
# stages. Stays root:root — see the PRIVILEGE SEPARATION note at the top
# of this file for why that's load-bearing, not incidental.
cp "$PKI_DIR/node.crt" "$RUNTIME_DIR/node.crt"
cp "$PKI_DIR/node.key" "$RUNTIME_DIR/node.key"
cp "$PKI_DIR/ca-bundle.crt" "$RUNTIME_DIR/ca-bundle.crt"
chmod 600 "$RUNTIME_DIR/node.key"
chmod 644 "$RUNTIME_DIR/node.crt" "$RUNTIME_DIR/ca-bundle.crt"

log "bootstrap bundle + node mTLS identity staged root-only at $RUNTIME_DIR (mcp_credentials.json, gitea_credentials.json, deploy_key, known_hosts, node.crt, node.key, ca-bundle.crt) — none of it is readable by the pnagent sandbox user"
