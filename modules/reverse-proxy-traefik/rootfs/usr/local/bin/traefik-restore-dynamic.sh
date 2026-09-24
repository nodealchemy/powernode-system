#!/bin/sh
# Restore the persisted host-login ingress config BEFORE traefik starts.
#
# The problem this closes: on a module-composed node without the durable
# symlink described below, /etc/traefik/dynamic can be empty at boot (a
# fresh overlay upper, or a wiped /persist). The real config (routers + the
# tls.options.default clientAuth block) is written by hub-backend's
# Core::IngressConfigWriter, which cannot run until Rails has booted —
# measured ~2 minutes. Until it lands, traefik serves TLS but never sends a
# CertificateRequest, so every agent handshake in that window yields a
# connection with no client certificate and the platform 401s everything on
# it. Core::IngressConfigWriter therefore also mirrors the file next to the
# certs it references, on /persist; this script copies that mirror into
# place at start.
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
#
# COMPOSED-NODE CASE: on a module-composed node, the agent's
# applyTraefikIngressPersistence (compose.go:531) makes $DST_DIR itself a
# symlink straight to $SRC_DIR — the "restore" traefik would read is already
# the durable copy in place, so there is nothing to copy. That is expected
# and handled below (INFO, exit 0), not treated as an attack.
#
# SECURITY (IMP-7e08f1514046, review round 2): $SRC_DIR is 2775 root:traefik
# with no sticky bit, and the rails service user is a member of the traefik
# group — so anything running with rails's privileges can create or replace
# files there. This script runs as root at every boot. Before the first fix
# round, `[ -f ]` alone followed a symlink and copied the TARGET's content
# into a 0644 file under $DST_DIR — an arbitrary-file-read made durable on
# /persist since the copy survives reboots. The first round closed the
# symlink path but missed a HARDLINK: a hardlink to a root-readable-only
# file (e.g. the agent's pki/node.key) is a regular file in its own right —
# it passes `-L` and `-f` cleanly, since the kernel enforces access on the
# OPEN, not on a path test this script could be tricked about. Round 2 closes
# that by reading $SRC with DROPPED privileges (setpriv, uid 65534/nobody —
# not the traefik user, which owns acme.json) so the kernel's own permission
# check decides whether the read succeeds, with a byte cap (1 MiB) and a
# timeout (10s) so a FIFO or an endless/oversized source can't hang the boot
# or exhaust memory. The whole read result is captured to a root-only
# staging file BEFORE anything is trusted — the referenced-cert-path check
# and the eventual publish both operate on that captured copy, never on
# $SRC again. Fixed by:
#   1. Refusing outright the moment $SRC is a symlink (`-L`, checked BEFORE
#      `-f`, live-target or dangling) or anything but a regular file
#      (belt-and-braces alongside the privileged-read defense below, which
#      is what actually closes the hardlink gap this alone cannot).
#   2. Reading $SRC as an unprivileged reader (setpriv --reuid=65534
#      --regid=<traefik gid> --clear-groups --no-new-privs), under `timeout
#      10`, capped at 1 MiB (`head -c`) — a hardlink to a file that uid
#      65534 cannot open simply fails to read, exactly as it would for any
#      other unprivileged process; a FIFO or oversized source is bounded by
#      the cap and the timeout instead of blocking or growing unbounded.
#      The captured copy lands in a root-only (0700) staging directory.
#   3. The referenced-cert-path existence check also runs as the SAME
#      unprivileged reader (`$RD test -f`), against the captured copy's
#      content — not as root against attacker-chosen paths, which would
#      otherwise be a root existence-oracle for arbitrary filesystem paths.
#   4. The staging directory is built under $(dirname "$DST_DIR") — NOT
#      inside $DST_DIR itself, and $DST_DIR is never chowned: $DST_DIR is
#      2775 root:traefik specifically so the non-root rails service can
#      later write $NAME itself (rails-setup.sh); taking that away here
#      would break rails's own ingress-config path. $(dirname "$DST_DIR")
#      (normally /etc/traefik) is root:root 0755 and not attacker-writable,
#      and is itself refused if ever replaced by a symlink. The staging
#      directory is removed on every exit path via a trap.
#   5. Publishing with `mv -f -T`, which refuses to treat the destination as a
#      directory even if $DST_DIR/$NAME were ever replaced by a
#      symlink-to-directory (a plain `mv` would move the temp file INSIDE it
#      instead of replacing it in place).
#
# Refusals are logged at WARNING (the `<4>` prefix is systemd's stream
# priority convention — see sd-daemon(3) — parsed by journald since this
# unit's StandardError=journal): every refusal means the clientAuth window
# this script exists to close stays open, which is operationally
# significant and must not be buried at the routine-status INFO level.
# The composed-node case and first-boot are expected outcomes, not
# refusals, and stay at INFO.
#
# Audited every other root operation in this module (its only other unit,
# `traefik` itself, runs as User=traefik — never root) and found none: this
# script is the sole root-executing command the module ships. The sibling
# finding in the SAME durable directories — rails-setup.sh's plain
# `chown`/`chmod` over a rails-writable tree, which follows a symlink
# argument — is fixed separately in that script (see its own IMP note).
#
# ROUND 4: on cloud_init-model nodes the agent's per-unit capabilities
# drop-in leaves this unit with no CAP_SETUID/CAP_SETGID, so setpriv can
# never drop privileges there at all. See the fallback block below (search
# "ROUND 4") for the guarded root-read path that keeps this script working
# on that node class without regressing to the pre-fix behavior.
set -u

SRC_DIR="${POWERNODE_TRAEFIK_DYNAMIC_PERSIST_DIR:-/persist/powernode-traefik/dynamic}"
DST_DIR="${POWERNODE_TRAEFIK_DYNAMIC_DIR:-/etc/traefik/dynamic}"
NAME="00-host-login.yaml"
SRC="${SRC_DIR}/${NAME}"
MAX_BYTES=1048576
READ_TIMEOUT=10

log_info() { echo "[traefik-restore-dynamic] $*"; }
log_warn() { echo "<4>[traefik-restore-dynamic] WARNING: $*" >&2; }

STAGING=""
cleanup() {
  [ -n "$STAGING" ] && [ -d "$STAGING" ] && rm -rf "$STAGING"
}
trap cleanup EXIT
# review round 3: in dash (and POSIX shells generally), `trap cleanup TERM`
# with no `exit` inside the handler means the trap runs and the SCRIPT
# CONTINUES from wherever it was interrupted — trapping a signal replaces
# its default disposition (terminate) entirely, it doesn't restore it
# afterward. A boot-critical unit stopped by systemd (or hitting
# TimeoutStartSec) would not actually stop: it would fall through the rest
# of this script with $STAGING already removed by cleanup(), hit a string
# of harmless-looking `|| true`-guarded failures, and still exit 0 — which
# LOOKS identical to a clean stop from the outside (verified: it does, in
# fact, still converge on "no file written" here) but is not one; a
# slightly different script shape could easily let it complete the very
# restore it was asked to abandon. `exit 0` here is what actually stops the
# process; it triggers the EXIT trap above too, so cleanup still runs.
trap 'exit 0' INT TERM HUP

# Belt-and-braces alongside the privileged read below (which is what
# actually closes the hardlink gap this alone cannot): refuses a symlinked
# or non-regular source outright, before any privilege is spent on it.
src_is_unsafe() {
  if [ -L "$SRC" ]; then
    return 0
  fi
  if [ ! -f "$SRC" ]; then
    return 0
  fi
  return 1
}

# The staging directory's PARENT must be refused BEFORE anything below is
# allowed to touch $DST_DIR at all: `mkdir -p "$DST_DIR"` itself follows a
# symlinked PARENT component (it has no -L check of its own) and would
# create the "dynamic" entry through it — landing wherever that link points
# — before any check on $DST_DIR could catch it. Checking the parent first,
# on the path alone (no mkdir yet), closes that window entirely.
STAGING_PARENT="$(dirname "$DST_DIR")"
if [ -L "$STAGING_PARENT" ]; then
  log_warn "$STAGING_PARENT is a symlink — will not create anything through it"
  exit 0
fi

# The watched directory must exist regardless — traefik's file provider logs
# "Cannot start the provider" and never begins watching if it is absent, which
# would ignore the config Rails writes later too.
mkdir -p "$DST_DIR" 2>/dev/null || true

if [ -L "$DST_DIR" ]; then
  DST_REAL="$(realpath "$DST_DIR" 2>/dev/null || true)"
  SRC_REAL="$(realpath "$SRC_DIR" 2>/dev/null || true)"
  if [ -n "$DST_REAL" ] && [ "$DST_REAL" = "$SRC_REAL" ]; then
    log_info "watched dir is the durable dir ($DST_DIR -> $DST_REAL); nothing to restore"
    exit 0
  fi
  log_warn "$DST_DIR is a symlink to something other than the durable dir ($SRC_DIR) — will not follow it"
  exit 0
fi

if src_is_unsafe; then
  if [ -L "$SRC" ]; then
    log_warn "$SRC is a symlink — will not follow it"
  elif [ -e "$SRC" ]; then
    log_warn "$SRC exists but is not a regular file (directory, device, FIFO, or similar) — refusing"
  else
    log_info "no persisted config at $SRC — first boot, or Rails has not written one yet; starting clean"
  fi
  exit 0
fi

TRAEFIK_GID="$(getent group traefik 2>/dev/null | cut -d: -f3)"
if [ -z "$TRAEFIK_GID" ]; then
  log_warn "could not resolve the traefik group gid — starting without the persisted config"
  exit 0
fi

# uid 65534 (nobody), not the traefik user: traefik itself owns acme.json,
# which this reader must not be able to read either.
RD="setpriv --reuid=65534 --regid=${TRAEFIK_GID} --clear-groups --no-new-privs --"

STAGING="$(mktemp -d "${STAGING_PARENT}/.traefik-restore.XXXXXX" 2>/dev/null || true)"
if [ -z "$STAGING" ] || [ ! -d "$STAGING" ]; then
  log_warn "could not create a root-only staging dir under $STAGING_PARENT — starting without the persisted config"
  exit 0
fi
chown root:root "$STAGING" 2>/dev/null || true
chmod 0700 "$STAGING" 2>/dev/null || true

CONTENT="${STAGING}/content"
# The kernel's own permission check on this OPEN — not a path test this
# script could be tricked about — is what actually stops a hardlink to a
# root-only file: uid 65534 simply cannot open it, same as any other
# unprivileged reader. `head -c` bounds a FIFO or an oversized/endless
# source to MAX_BYTES+1; `timeout` bounds one that blocks on open (a FIFO
# with no writer) instead of hanging the boot.
timeout "$READ_TIMEOUT" $RD head -c $((MAX_BYTES + 1)) -- "$SRC" > "$CONTENT" 2>/dev/null
READ_STATUS=$?

# ROUND 4 (boot-safety critic): on cloud_init-model nodes, the agent writes
# a capabilities.conf drop-in on EVERY unit in this module — including
# restore-dynamic — with CapabilityBoundingSet=CAP_NET_BIND_SERVICE, which
# has no CAP_SETUID/CAP_SETGID. setpriv can then never exec at all
# ("setresuid failed: Operation not permitted"), and util-linux's setpriv
# exits 127 for exactly that failure — distinct from head's own exit codes
# for an actual read failure (permission denied, EOF, etc.) or timeout's
# 124 for an actual timeout. Composed/pivot nodes carry no such drop-in and
# are unaffected. Falling back to a GUARDED ROOT READ rather than refusing
# outright (which would silently regress this node class versus the
# pre-fix script, which read as root and worked fine there): the -L/-f
# checks are re-verified (belt-and-braces, narrows the check-to-read
# window further), and — since a privilege drop is no longer available to
# let the kernel itself reject a hardlink — a hardlink is refused
# explicitly via `stat -c %h` (exactly-1 hard link required). This
# capability is intentionally NOT added to the module's
# security.capabilities: that list is module-wide and would become ambient
# on the `traefik` service too, a materially bigger grant than one script
# occasionally needing a same-node fallback.
if [ "$READ_STATUS" -eq 127 ]; then
  log_info "cannot drop privileges on this node (setpriv exited 127 — likely a CapabilityBoundingSet drop-in without CAP_SETUID/CAP_SETGID); falling back to a guarded root read"

  if src_is_unsafe; then
    log_warn "$SRC changed or is unsafe at fallback-read time — will not restore"
    exit 0
  fi

  SRC_NLINK="$(stat -c %h "$SRC" 2>/dev/null || echo 0)"
  if [ "$SRC_NLINK" != "1" ]; then
    log_warn "$SRC has $SRC_NLINK hard link(s) (expected exactly 1) — refusing a hardlinked source without a privilege drop available to verify it"
    exit 0
  fi

  # No setpriv wrapper below this point: RD is now empty, so the
  # referenced-cert-path check further down runs a plain `test -f` too,
  # not a privileged existence-oracle-avoiding check — root already read
  # this content directly above, so there is nothing left to avoid.
  RD=""
  timeout "$READ_TIMEOUT" head -c $((MAX_BYTES + 1)) -- "$SRC" > "$CONTENT" 2>/dev/null
  READ_STATUS=$?
fi

if [ "$READ_STATUS" -ne 0 ]; then
  log_warn "could not read $SRC (permission denied, not readable, or timed out) — will not restore"
  exit 0
fi

READ_BYTES="$(wc -c < "$CONTENT" 2>/dev/null || echo 0)"
if [ "$READ_BYTES" -gt "$MAX_BYTES" ]; then
  log_warn "$SRC exceeds the ${MAX_BYTES}-byte cap (read ${READ_BYTES}+ bytes) — refusing an oversized or endless source"
  exit 0
fi

# Every absolute *.crt/*.key path the CAPTURED COPY references must exist
# and be readable to the SAME unprivileged reader — never as root against
# attacker-chosen paths, which would otherwise be a root existence-oracle
# for arbitrary filesystem paths.
#
# MUST STAY FAIL-OPEN (review round 3): each path below forks setpriv+test
# once. Uncapped, a source with tens of thousands of distinct caFiles
# entries would take minutes — overrunning the unit's TimeoutStartSec=30,
# failing this boot-critical oneshot, and taking traefik down with it via
# Requires= over a config problem that was never traefik's fault. Capped at
# 64 distinct paths (`sort -u | head -n 65`: 65 lines back means MORE than
# 64 unique paths existed) so this step always finishes in a bounded,
# small number of forks regardless of how large or repetitive $SRC is.
REFS="$(grep -oE '/[A-Za-z0-9._/-]+\.(crt|key)' "$CONTENT" | sort -u | head -n 65)"
if [ -n "$REFS" ]; then
  REF_COUNT="$(printf '%s\n' "$REFS" | wc -l)"
else
  REF_COUNT=0
fi
if [ "$REF_COUNT" -gt 64 ]; then
  log_warn "$SRC references more than 64 distinct cert/key paths — refusing rather than risk overrunning this unit's boot timeout with one privileged check per path"
  exit 0
fi

missing=""
for f in $REFS; do
  $RD test -f "$f" 2>/dev/null || missing="${missing} ${f}"
done

if [ -n "$missing" ]; then
  log_warn "referenced file(s) missing or unreadable as an unprivileged reader:${missing} — restoring would break ALL TLS on the entrypoint; starting without it instead"
  exit 0
fi

chown root:root "$CONTENT" 2>/dev/null || true
chmod 0644 "$CONTENT" 2>/dev/null || true

# Atomic and never touches $DST_DIR's own ownership/mode: mv -f -T refuses
# to treat the destination as a directory even if $DST_DIR/$NAME were ever
# replaced by a symlink-to-directory.
if mv -f -T "$CONTENT" "${DST_DIR}/${NAME}" 2>/dev/null; then
  log_info "restored ${NAME} from $SRC — clientAuth is in force from first handshake"
else
  log_warn "restore failed (non-fatal); starting without it"
fi

exit 0
