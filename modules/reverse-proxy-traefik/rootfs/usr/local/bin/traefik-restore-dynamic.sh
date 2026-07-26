#!/bin/sh
# Restore the persisted host-login ingress config BEFORE traefik starts.
#
# The problem this closes: /etc/traefik/dynamic is an overlay whose upper layer
# is tmpfs on a module-composed node, so it is EMPTY at every boot. The real
# config (routers + the tls.options.default clientAuth block) is written by
# hub-backend's Core::IngressConfigWriter, which cannot run until Rails has
# booted — measured ~2 minutes. Until it lands, traefik serves TLS but never
# sends a CertificateRequest, so every agent handshake in that window yields a
# connection with no client certificate and the platform 401s everything on it.
# Core::IngressConfigWriter therefore also mirrors the file next to the certs it
# references, on /persist; this script copies that mirror into place at start.
#
# WHY THE GUARD IS MANDATORY, not defensive politeness: a tls.options block
# whose clientAuth.caFiles path does not exist makes traefik fail to build the
# DEFAULT TLS configuration ("invalid certificate(s) content") and then ALL TLS
# on the entrypoint is dead — openssl s_client cannot even complete a handshake.
# On a first boot, or any boot with a wiped /persist, the internal CA does not
# exist yet. Copying in a config that references it would take the whole ingress
# down, which is far worse than the 2-minute window this exists to remove. So:
# copy only if the mirror AND every file it references are present, and exit 0
# no matter what — traefik must always start.
#
# Referenced paths are extracted FROM the YAML rather than hardcoded, because
# the cert directory is operator-configurable (POWERNODE_TRAEFIK_CERT_DIR, and
# /persist vs /var/lib depending on the node).
#
# Verified against the pinned traefik (3.7.1): duplicate tls.options.default
# across two dynamic files resolves LEXICALLY-FIRST-file-wins with a silent
# "options already configured, skipping" warning. This writes the SAME filename
# Rails later rewrites, so there is never a second definition to lose that race.
set -u

SRC_DIR="${POWERNODE_TRAEFIK_DYNAMIC_PERSIST_DIR:-/persist/powernode-traefik/dynamic}"
DST_DIR="${POWERNODE_TRAEFIK_DYNAMIC_DIR:-/etc/traefik/dynamic}"
NAME="00-host-login.yaml"
SRC="${SRC_DIR}/${NAME}"

log() { echo "[traefik-restore-dynamic] $*"; }

# The watched directory must exist regardless — traefik's file provider logs
# "Cannot start the provider" and never begins watching if it is absent, which
# would ignore the config Rails writes later too.
mkdir -p "$DST_DIR" 2>/dev/null || true

if [ ! -f "$SRC" ]; then
  log "no persisted config at $SRC — first boot, or Rails has not written one yet; starting clean"
  exit 0
fi

# Every absolute *.crt/*.key path the config references must exist, or traefik
# will refuse to build the default TLS config and drop TLS entirely.
missing=""
for f in $(grep -oE '/[A-Za-z0-9._/-]+\.(crt|key)' "$SRC" | sort -u); do
  [ -f "$f" ] || missing="${missing} ${f}"
done

if [ -n "$missing" ]; then
  log "REFUSING to restore: referenced file(s) missing:${missing}"
  log "restoring would break ALL TLS on the entrypoint; starting without it instead"
  exit 0
fi

# Atomic: traefik's file provider watches this directory and may read mid-copy.
TMP="${DST_DIR}/.${NAME}.tmp.$$"
if cp "$SRC" "$TMP" 2>/dev/null && chmod 0644 "$TMP" 2>/dev/null && mv -f "$TMP" "${DST_DIR}/${NAME}" 2>/dev/null; then
  log "restored ${NAME} from $SRC — clientAuth is in force from first handshake"
else
  rm -f "$TMP" 2>/dev/null || true
  log "restore failed (non-fatal); starting without it"
fi

exit 0
