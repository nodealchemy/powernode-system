#!/bin/bash
# dev-cell-provision.sh — first-boot (and idempotent-on-restart) workspace
# provisioning for the campaign dev-cell. PRIVILEGE-SEPARATED: this script
# (root) does ONLY the phases that need the Gitea deploy key — clone,
# submodules, private-extensions — then hands the workspace off to the
# unprivileged pnagent sandbox user for everything else (bundle, npm, the
# test DB) via dev-cell-provision-pnagent.sh, run through `runuser`. See
# this module's manifest.yaml description for the full rationale: pnagent
# never touches the deploy key, so it can't authenticate to Gitea at all,
# only read/write inside the workspace it's been chowned.
#
# Runs as ROOT (After=/Requires= dev-cell-bootstrap.service, which staged
# the Gitea SSH deploy key + known hosts this script reads — root-only,
# 0600, never chowned to pnagent).
#
# ADAPTED from scripts/prepare-worktree.sh and
# scripts/prepare-extension-test-db.sh for a standalone-instance first boot
# rather than a worktree-of-a-main-checkout: there is no sibling "main
# checkout" here to symlink gitignored secrets from, so
# dev-cell-provision-pnagent.sh generates server/config/database.yml and
# server/.env/worker/.env from the repo's own tracked *.example templates
# instead of symlinking, and reuses the CLONED repo's own
# scripts/prepare-extension-test-db.sh verbatim for the test-DB build
# (core vs. private-extension mode is already handled there).
#
# Idempotent: each phase is gated by its own marker file under
# $STATE_DIR/state/ (a persistent FHS path, NOT under either user's
# $HOME — both this script's own root-run phases and
# dev-cell-provision-pnagent.sh's pnagent-run phases share it), so a
# re-run (systemd Restart=on-failure on this oneshot unit, or a plain
# reboot) resumes instead of redoing finished work. The final
# "provisioned" marker is written LAST, after every phase in BOTH halves
# succeeds — a partial failure under `set -e` (in this script OR,
# propagated via runuser's exit code, in the pnagent phase) leaves it
# unwritten, so dev-cell-executor.service's ConditionPathExists never
# fires on a half-provisioned workspace.
set -euo pipefail

# Unattended: a git operation that would otherwise prompt for credentials
# (wrong host, a private-extension repo the deploy key has no access to)
# must fail fast, not hang this oneshot unit forever waiting on a TTY that
# will never answer.
export GIT_TERMINAL_PROMPT=0

DEV_CELL_RUNTIME_DIR="${DEV_CELL_RUNTIME_DIR:-/run/dev-cell}"
PNAGENT_USER="${DEV_CELL_PNAGENT_USER:-pnagent}"
# BUG-D: default the workspace AND the provision state onto the durable
# /persist volume (12G ext4 on a pivot cell), NOT /home + /var — both live on
# the 512M tmpfs ROOT overlay, far too small for a platform workspace
# (bundle + node_modules + test DB) and wiped on every reboot. Co-locating
# STATE_DIR with WORKDIR on /persist is REQUIRED, not cosmetic: the clone
# guard below rm-rf's $WORKDIR whenever its `clone` marker is missing, so a
# durable WORKDIR paired with an ephemeral (overlay) marker would nuke the
# persisted workspace on every boot. Co-locating both also yields correct
# warm-restart — the persisted `provisioned` marker keeps this unit's
# ConditionPathExists=!MARKER from needlessly re-running provision and lets
# dev-cell-executor.service start straight against the warm workspace.
# FLAGGED to the unit migration (bug1): dev-cell-provision.service's
# ConditionPathExists=!/var/lib/dev-cell/provisioned and
# dev-cell-executor.service's ConditionPathExists=/var/lib/dev-cell/provisioned
# must move to /persist/dev-cell/state/provisioned to match STATE_DIR here.
WORKDIR="${DEV_CELL_WORKDIR:-/persist/dev-cell/workspace}"
STATE_DIR="${DEV_CELL_STATE_DIR:-/persist/dev-cell/state}"
STEP_DIR="$STATE_DIR/state"
MARKER="$STATE_DIR/provisioned"
PNAGENT_PHASE_SCRIPT="${DEV_CELL_PNAGENT_PHASE_SCRIPT:-/usr/local/bin/dev-cell-provision-pnagent.sh}"

log() { echo "dev-cell-provision: $*"; }
done_step() { [ -e "$STEP_DIR/$1" ]; }
mark_step() { mkdir -p "$STEP_DIR"; : > "$STEP_DIR/$1"; }

if [ -e "$MARKER" ]; then
  log "already provisioned ($MARKER exists) — no-op"
  exit 0
fi

mkdir -p "$STATE_DIR" "$STEP_DIR"
# pnagent's own phase (dev-cell-provision-pnagent.sh, via runuser below)
# needs to read/write the SAME step markers — hand the whole (secret-free;
# these are empty marker files) state dir over once, up front.
chown -R "$PNAGENT_USER:$PNAGENT_USER" "$STATE_DIR"

# --- 0. preflight — verify co-required modules are actually present ------
# As of 2026-07-28 these are real `capability:` edges in the manifest
# (runtime.ruby / runtime.node / runtime.go / database.postgres), so the
# resolver pulls them into any composition containing dev-cell and a template
# can no longer be built without them. This preflight is therefore now
# DEFENCE IN DEPTH, not the primary protection — it still earns its place:
#   - a capability that no published module provided yet is skipped silently
#     at manifest import, so an edge can be quietly absent;
#   - assignments can be disabled per-node after resolution;
#   - it catches a module that composed but whose binary is missing/broken,
#     which no dependency edge can express.
# `runuser` is a hard dependency (util-linux, via powernode-system-base),
# checked for the same reason. Fail here with a clear message instead of a
# cryptic "command not found" deep inside a later phase.
for cmd in bundle npm node go psql pg_isready createuser runuser; do
  command -v "$cmd" >/dev/null 2>&1 || {
    log "missing '$cmd' — is this instance's NodeTemplate missing a co-required module (runtime-ruby / runtime-node / runtime-go / postgres-primary), or util-linux broken?"
    exit 1
  }
done
# Assert the Go toolchain satisfies agent/go.mod's directive (runtime-go ships
# 1.26.x; Noble's apt Go is 1.22). go(1) refuses to build when the toolchain is
# OLDER than the `go` directive, so a stale toolchain fails the Go half of
# scripts/validate.sh with a confusing compile error deep in the run. Same
# shape, and same reasoning, as the Node 24 assertion below.
GO_MINOR=$(go version 2>/dev/null | sed -n 's/^go version go1\.\([0-9]\{1,\}\).*/\1/p')
if [ "${GO_MINOR:-0}" -lt 25 ]; then
  log "go is 'go1.${GO_MINOR:-<none>}' (<1.25) — the runtime-go module is missing from this NodeTemplate or is stale; agent/go.mod declares go 1.25.0 and go(1) will not build below its own directive."
  exit 1
fi
# Assert Node 24+ (runtime-node), not Noble's stale apt v18: a bare `command -v
# node` passes on v18, but the frontend needs engines >=24.9, and v18 lacks npm
# and SIGABRTs on V8 snapshot init in this pivot env. `node --version` on a
# broken/old node yields a non-24 major (or errors → empty → treated as 0), so
# fail clearly here rather than deep inside `npm ci` / the mcp-proxy crash-loop.
NODE_MAJOR=$(node --version 2>/dev/null | sed -n 's/^v\([0-9]\{1,\}\).*/\1/p')
if [ "${NODE_MAJOR:-0}" -lt 24 ]; then
  log "node major is '${NODE_MAJOR:-<none>}' (<24) — the runtime-node module (Node 24) is missing from this NodeTemplate; apt's v18 fallback can't build the frontend or run the mcp-proxy."
  exit 1
fi

# --- deploy key + known_hosts + clone_url, read fresh from tmpfs ---------
# Root-owned, 0600 — this script runs as root, so it can read them
# regardless (no chown needed, unlike the pre-privilege-separation
# version of this module).
GITEA_FILE="$DEV_CELL_RUNTIME_DIR/gitea_credentials.json"
[ -r "$GITEA_FILE" ] || { log "no Gitea credentials at $GITEA_FILE — did dev-cell-bootstrap.service run?"; exit 1; }

CLONE_URL=$(jq -r '.clone_url // empty' "$GITEA_FILE")
[ -n "$CLONE_URL" ] || { log "gitea_credentials.json is missing clone_url"; exit 1; }

# NOTE on GIT_SSH_COMMAND scoping: dev-cell-git-ssh-env.sh is
# DELIBERATELY NOT sourced here at top level (a prior version of this
# script did — that was a real bug, M4). `export`ing GIT_SSH_COMMAND into
# this script's own persistent environment would leak it into the
# runuser call in step 6 below EVEN WITHOUT `-p`/`--preserve-environment`
# — verified empirically that `runuser -u X -- ...` resets specific
# well-known vars (HOME, PATH) to safe target-user defaults but otherwise
# passes the CALLER's ambient exported environment straight through; the
# `env VAR=val` prefix on that call ADDS variables, it is not a
# whitelist that clears anything else. Defense in depth: it is instead
# sourced in a SUBSHELL immediately around the one `git clone` command
# that needs it, in step 2 below — verified empirically (same technique
# as dev-cell-executor.sh) that a subshell-scoped `export` inside a
# sourced script does NOT leak into the parent shell's environment, and
# that the sourced script's fail-closed `return 1` still short-circuits
# the following `&&`-chained git command while propagating its exit
# status out to the caller.

# SSH-form clone_url is "git@host:owner/repo.git" (or "ssh://git@host:port/owner/repo.git").
GITEA_HOST=$(printf '%s' "$CLONE_URL" | sed -E 's#^(ssh://)?[^@]+@([^:/]+).*#\2#')

# --- 1. git identity ---------------------------------------------------------
# --system, not --global: root does the clone/submodules/push, but
# pnagent does the actual `git commit` during stage1 (implement) — a
# SYSTEM-scoped identity (/etc/gitconfig) is visible to both users'
# git invocations, where a --global one (~/.gitconfig) would only cover
# whichever user set it. No credential.helper / .git-credentials step —
# auth is the SSH deploy key via GIT_SSH_COMMAND above, never a persisted
# dotfile secret.
if ! done_step git-identity; then
  git config --system user.name "Powernode Dev-Cell"
  git config --system user.email "dev-cell@${GITEA_HOST}"
  mark_step git-identity
  log "git identity configured (system-wide) for $GITEA_HOST"
fi

# --- 2. clone the main repo (root — needs the deploy key) ------------------
if ! done_step clone; then
  if [ -e "$WORKDIR" ]; then
    # `git clone` refuses a non-empty target dir — a prior failed attempt
    # (interrupted mid-clone, or before this fix existed) would otherwise
    # brick every future boot forever since $WORKDIR persists across
    # reboots (unlike $DEV_CELL_RUNTIME_DIR). Safe to discard: nothing
    # under an unmarked-complete clone is ever depended on.
    log "clearing incomplete workspace at $WORKDIR from a prior failed clone attempt"
    rm -rf "$WORKDIR"
  fi
  mkdir -p "$(dirname "$WORKDIR")"
  # shellcheck source=dev-cell-git-ssh-env.sh
  # Exports GIT_SSH_COMMAND pointed at $DEV_CELL_RUNTIME_DIR/deploy_key +
  # known_hosts; fails closed (non-zero, caught by `set -e` since this
  # whole compound command is used directly as a statement, not inside a
  # condition) if known_hosts is empty and DEV_CELL_ALLOW_TOFU isn't
  # explicitly set — see that script. Subshell-scoped (see the NOTE
  # above) so GIT_SSH_COMMAND never persists into this script's own
  # environment.
  (
    . /usr/local/bin/dev-cell-git-ssh-env.sh
    git clone --origin origin "$CLONE_URL" "$WORKDIR"
  )
  mark_step clone
  log "cloned $GITEA_HOST -> $WORKDIR"
else
  log "repo already cloned at $WORKDIR"
fi

cd "$WORKDIR"

# --- 3. public extension submodules (root, anonymous HTTPS) ----------------
# These are GitHub-hosted (per .gitmodules) public/MIT submodules — no
# credential needed; anonymous HTTPS clone works.
if ! done_step submodules; then
  git submodule update --init --recursive
  mark_step submodules
  log "public extension submodules initialized"
fi

# --- 4. private extensions (best-effort — OPEN CONTRACT GAP) ---------------
# The pinned dev_cell_bootstrap contract only documents ONE gitea
# credential: a per-repo, read-write SSH deploy key scoped to the single
# source repo cloned above. Private extensions are gitignored, SEPARATE
# Gitea repos — even if the bootstrap bundle grows a (not part of the
# pinned contract — forward-compatible, optional) array at
# .private_extension_repos: [{"name": "...", "clone_url": "..."}, ...],
# this deploy key cannot authenticate to a DIFFERENT repo (System::
# DevCellDeployKey is one key per NodeInstance per source_repo). Cloning a
# private extension would need its OWN per-repo deploy key issued the same
# way — not part of this contract today. This step therefore stays a
# structural no-op under the current contract; kept (rather than deleted)
# so it activates for free if that gap is later closed server-side.
# Absent it, provisioning proceeds in CORE MODE — the same degrade path
# scripts/prepare-worktree.sh documents.
if ! done_step private-extensions; then
  PRIVATE_COUNT=$(jq -r '(.private_extension_repos // []) | length' "$GITEA_FILE")
  if [ "$PRIVATE_COUNT" -gt 0 ]; then
    log "WARNING: bootstrap bundle has ${PRIVATE_COUNT} private_extension_repos entries, but the current deploy key is scoped to ${CLONE_URL} only — skipping (see this step's comment)"
  else
    log "no private_extension_repos in bootstrap bundle — provisioning in CORE MODE"
  fi
  mark_step private-extensions
fi

# --- 5. hand the workspace off to pnagent -----------------------------------
# Everything from here on (bundle, npm, the test DB, and later
# scripts/validate.sh + headless `claude` itself) runs as pnagent — it
# needs read/write in $WORKDIR but NEVER needs (and never gets) the
# deploy key. etcidentity only renders /etc/passwd et al., not home
# directories (see agent/internal/etcidentity/doc.go) — create pnagent's
# home explicitly, same as redis's own precedent for a module-owned
# service account.
if ! done_step chown-workspace; then
  # /home ships 0700 root:root on the dev-cell rootfs, which blocks pnagent
  # (the owner of everything under /home/pnagent) from even TRAVERSING into
  # its own chowned workspace — the pnagent hand-off's first `cd "$WORKDIR"`
  # fails with EACCES at the /home hop, not on the workspace itself. Widen
  # /home to 0711 (traverse, not list) so the unprivileged sandbox can reach
  # its home; /home/pnagent below stays 0700 (private) via the chmod after.
  chmod 0711 /home
  mkdir -p "/home/$PNAGENT_USER"
  chown "$PNAGENT_USER:$PNAGENT_USER" "/home/$PNAGENT_USER"
  chmod 700 "/home/$PNAGENT_USER"
  # BUG-D: the frontend npm download cache (~/.npm) would otherwise land on
  # the 512M tmpfs overlay via pnagent's $HOME. Pre-create a /persist-backed,
  # pnagent-owned cache dir beside the workspace (the /persist/dev-cell parent
  # is root-owned, so pnagent can't mkdir it itself); dev-cell-provision-
  # pnagent.sh points npm_config_cache here so `npm ci` never touches the overlay.
  mkdir -p "$(dirname "$WORKDIR")/npm-cache"
  chown "$PNAGENT_USER:$PNAGENT_USER" "$(dirname "$WORKDIR")/npm-cache"
  chown -R "$PNAGENT_USER:$PNAGENT_USER" "$WORKDIR"
  mark_step chown-workspace
  log "workspace at $WORKDIR handed off to $PNAGENT_USER"
fi

# --- 6. pnagent-side provisioning (runtime-config/bundle/frontend/pg-ready/
# pg-role/test-db) — a SEPARATE script, not inlined here, so the
# root/pnagent boundary in this file is a single, auditable line rather
# than scattered `runuser` calls threaded through the rest of the phases.
# No outer step marker needed: dev-cell-provision-pnagent.sh tracks its
# OWN sub-steps against the same $STEP_DIR, so re-invoking it (e.g. on a
# provision.service restart) is already a fast no-op once genuinely done.
# DEV_CELL_WORKDIR/DEV_CELL_STATE_DIR are passed explicitly via `env` —
# both are plain paths, not secrets, so passing them via argv is fine.
# GIT_SSH_COMMAND is NOT among them and never leaks here either way: it
# was only ever exported inside the subshell around step 2's `git clone`
# (see the NOTE above step 2), so by this point in the script it was
# never part of this script's own persistent environment for `runuser`
# (with or without `-p`) to pass through in the first place.
runuser -u "$PNAGENT_USER" -- env \
  DEV_CELL_WORKDIR="$WORKDIR" \
  DEV_CELL_STATE_DIR="$STATE_DIR" \
  bash "$PNAGENT_PHASE_SCRIPT"

: > "$MARKER"
log "provisioning complete — $MARKER written"
