#!/bin/bash
# rails-setup.sh — ROOT-ONLY, one-time-per-boot prep for the non-root
# `rails` service (IMP-94977647c24c part A).
#
# WHY THIS IS A SEPARATE UNIT. The structured service fields the agent's
# unit renderer understands cannot express ExecStartPre (see
# agent/internal/lifecycle/service.go's renderUnitBodyMode doc comment,
# and reverse-proxy-traefik's own `restore-dynamic` oneshot, which solves
# the identical problem for the traefik service the same way). So root-only
# prep is a SEPARATE `Type=oneshot, RemainAfterExit=yes` unit
# (rails-setup.service), ordered `start_before` the real `rails` service
# via the manifest's `dependencies:`. Runs on EVERY boot (idempotent) —
# not because ownership can change, but because the WRITABLE overlay
# upper (and the non-persist STATE_DIR fallback) can be wiped clean on a
# pivot-composed reboot even though the target user's UID never does
# (System::ServiceUser allocates it once, platform-wide — see that
# model's doc comment).
#
# WHAT MOVED HERE FROM rails-start.sh, AND WHY EACH ONE NEEDED ROOT:
#   - mkdir/chmod STATE_DIR + chown to RAILS_USER: STATE_DIR sits under
#     /persist or /var/lib, both root-owned by default; a non-root
#     process cannot create a new entry there without help.
#   - BUNDLE_STATE_DIR (vendor/bundle, now under STATE_DIR, NOT under
#     /opt/powernode/server — see rails-start.sh's `bundle config set
#     --global` for why): same reasoning, same fix.
#   - config/database.yml: `/opt/powernode/server` is the erofs-backed
#     module mount (root:root by default), so a non-root process can't
#     create a NEW file there. Team-lead's plan preferred build-time
#     rendering; I could not find the exact hub-backend build hook in
#     .gitea/workflows/build-platform-modules.yaml (it does not
#     currently touch database.yml at all — this is a manifest+scripts
#     task, not a build-pipeline one, so I deliberately did not guess at
#     unfamiliar CI infrastructure). Root doing this ONE cp, once, here,
#     achieves the SAME property team-lead wanted (the non-root rails
#     process never writes it) without touching the build pipeline —
#     flagged to the operator as a "confirm or move to build time"
#     follow-up, not silently assumed equivalent.
#   - traefik's dynamic-config dir + cert dir (both the LIVE /etc/traefik
#     copy and the DURABLE /persist/powernode-traefik mirror): root:traefik
#     2775 (setgid) per team-lead's revised decision — NOT in
#     reverse-proxy-traefik's own oneshot, because cross-module boot ORDER
#     cannot be expressed (a module's `dependencies:`/`start_before` only
#     orders services WITHIN that module). This unit chowns/chmods the dirs
#     AND their EXISTING files (some ship root-owned 0600, e.g.
#     00-host-login.yaml from a prior root-run boot, or traefik:traefik
#     0755 with no group-write, e.g. the durable mirror before this fix)
#     so a non-root rails can REPLACE/CREATE them, not just read them.
#   - /persist/var/lib/powernode (the agent's enrolled-PKI parent): the
#     agent (root) owns this tree and it defaults to 0700 root:root, which
#     blocks a non-root rails from even TRAVERSING into it to read
#     ca-chain.crt for the client-auth CA bundle (Core::IngressConfigWriter
#     #prepare_client_auth_ca). Granted at 0710 (traverse only, no listing
#     — see the section's own comment for why 0750 here would have been
#     too wide) on the parent, 0750 on pki/ itself.
#   - The old /etc/powernode/{backend-default.conf,admin-credentials.json}
#     migration (pre-STATE_DIR hosts only): moved here (root) rather than
#     dropped outright, because /etc/powernode is root-owned and the
#     non-root rails process can no longer perform the mv itself. Real
#     files only (symlink-aware — never follows/moves a symlink), and
#     never overwrites an existing STATE_DIR file.
set -euo pipefail

RAILS_USER=powernode-rails
RAILS_DIR=/opt/powernode/server

if mountpoint -q /persist 2>/dev/null; then
  STATE_DIR=/persist/powernode-rails
else
  STATE_DIR=/var/lib/powernode-rails
fi
BUNDLE_STATE_DIR="$STATE_DIR/vendor/bundle"

echo "[rails-setup] STATE_DIR=$STATE_DIR"
mkdir -p "$STATE_DIR" "$BUNDLE_STATE_DIR"

# --- One-time migration of a pre-STATE_DIR host's leftover /etc/powernode
#     files. Symlink-aware (-L excludes a symlink — never moves/follows
#     one) and never clobbers an existing STATE_DIR file. Root-only
#     because /etc/powernode is root-owned; this used to run inside
#     rails-start.sh itself when that process was still root.
# crash-safe: `mv` ACROSS filesystems (/etc/powernode vs. /persist are
# different mounts) is not atomic — it degrades to copy+unlink, and a
# crash mid-copy leaves a TRUNCATED file at dest. The `[ ! -f "$dest" ]`
# guard above would then see that truncated file as "already migrated"
# forever, silently poisoning SECRET_KEY_BASE/admin credentials. Copy to
# a same-filesystem temp name, rename (atomic, since it's on the SAME fs
# as dest), THEN remove the source — the visible "did this land" step is
# a rename, not a cross-filesystem copy.
for f in backend-default.conf admin-credentials.json; do
  src="/etc/powernode/$f"
  dest="$STATE_DIR/$f"
  if [ -f "$src" ] && [ ! -L "$src" ] && [ ! -f "$dest" ]; then
    echo "[rails-setup] migrating legacy $src -> $dest"
    cp "$src" "$dest.tmp-$$"
    mv "$dest.tmp-$$" "$dest"
    rm -f "$src"
  fi
done

# One-time migration of the db:migrate/seed marker from the pre-STATE_DIR
# location. Moved HERE (root) from rails-start.sh, which could only
# attempt this best-effort (`|| true`) because a non-root process has no
# permission to touch a file /var/lib/powernode-rails left root-owned —
# root has no such problem, so this now either succeeds outright or
# genuinely doesn't apply (the marker was never there).
if [ -f /var/lib/powernode-rails/.db-initialized ] && [ ! -f "$STATE_DIR/.db-initialized" ]; then
  echo "[rails-setup] migrating legacy db-initialized marker into $STATE_DIR"
  # Same crash-safety reasoning as the secrets migration above: /var/lib
  # and /persist can be different filesystems, so a bare `mv` isn't atomic
  # here either.
  cp /var/lib/powernode-rails/.db-initialized "$STATE_DIR/.db-initialized.tmp-$$"
  mv "$STATE_DIR/.db-initialized.tmp-$$" "$STATE_DIR/.db-initialized"
  rm -f /var/lib/powernode-rails/.db-initialized
fi

# --- Bundler app config, persisted in STATE_DIR (not RAILS_DIR — the
#     module mount) so it survives independently of whatever rails-start.sh
#     exports for ITSELF. rails-start.sh's own BUNDLE_PATH/BUNDLE_WITHOUT
#     env exports already cover the service; this exists so an operator's
#     OUT-OF-BAND `bundle exec rails runner`/`console` (run manually, not
#     via the unit) also resolves the same vendored gem path, by pointing
#     BUNDLE_APP_CONFIG at this file instead of relying on the service's
#     env. Idempotent: rewritten every boot so a STATE_DIR path change
#     (mountpoint gained/lost) is never left stale.
mkdir -p "$STATE_DIR/.bundle"
cat > "$STATE_DIR/.bundle/config" <<EOF
---
BUNDLE_PATH: "$BUNDLE_STATE_DIR"
BUNDLE_WITHOUT: "development:test"
EOF

# FATAL: STATE_DIR itself and the two secrets files rails reads at boot.
# Adoption (b) originally made the WHOLE recursive sweep below fatal too
# ("a failure here means rails can't read its secrets") — review round
# correction: that reintroduces blocker 2's exact shape, just on a
# different pass. One stray unchownable entry ANYWHERE under STATE_DIR
# (a leftover root-owned file, an odd bind mount, an immutable bit
# somewhere deep in vendor/bundle) would fail rails-setup.service and
# stop Rails from starting at all — a problem having nothing to do with
# secrets taking down the one thing that DOES matter for secrets. Narrow
# the fatal part to exactly what regenerating SECRET_KEY_BASE under a
# live database would come from: STATE_DIR's own ownership/mode, and the
# two secrets files specifically. Absence is fine here (first boot, or a
# host that hasn't migrated legacy secrets) — `[ -e ]` guards that; an
# ACTUAL chown failure on a file that DOES exist still propagates via
# `set -e`, which is the point.
chown "$RAILS_USER:$RAILS_USER" "$STATE_DIR"
chmod 700 "$STATE_DIR"
for f in backend-default.conf admin-credentials.json; do
  secret_path="$STATE_DIR/$f"
  if [ -e "$secret_path" ]; then
    chown "$RAILS_USER:$RAILS_USER" "$secret_path"
  fi
done

# FATAL: the internal CA store (POWERNODE_CA_LOCAL_DIR), also part of the
# fatal set — review round correction, absorbed: the SECRET_KEY_BASE
# decision above is an EXISTENCE check (`[ ! -f "$SECRETS_FILE" ]` in
# rails-start.sh), not a readability one, so an unreadable secrets file
# doesn't silently regenerate anything — it makes the later `.
# "$SECRETS_FILE"` fail LOUDLY under set -e. The store that actually has
# the SILENT-rotation shape is the internal CA: System::InternalCaService
# #load_live/#load_legacy_pair gate on File.exist?, which reads false
# (not raised) for a present-but-untraversable directory — an unreadable
# legacy anchor looks identical to "nothing here yet", and
# generate_anchor! mints and persists a brand-new one successfully
# (because the NEW path is rails-owned). Every cert chained to the old
# anchor stops verifying, with nothing in the logs to say why. (The
# service itself no longer treats EACCES as absent — see
# internal_ca_service.rb's load_live/load_legacy_pair — but that fix only
# helps once this directory is actually traversable by rails; both
# halves are needed.)
#
# Resolve the SAME effective dir rails-start.sh resolves: read
# POWERNODE_CA_LOCAL_DIR out of the secrets file when it exists — an
# established deployment (ops-hub, confirmed live) can have it pointing
# OUTSIDE STATE_DIR entirely (/persist/powernode-internal-ca is a
# SIBLING of /persist/powernode-rails, which the STATE_DIR sweep below
# never reaches) — else fall back to rails-start.sh's own default,
# STATE_DIR/internal-ca. OWNERSHIP ONLY, no chmod: the anchor's key
# material is 0600 / its dirs 0700 by InternalCaService's own design and
# must survive unchanged — only the OWNER needs to change, from root (who
# created it) to rails (who now needs to read/extend it).
ca_local_dir=""
if [ -f "$STATE_DIR/backend-default.conf" ]; then
  # sed, NOT grep|cut (review round, BLOCKER 1): under set -euo
  # pipefail, grep exits 1 on NO MATCH — the COMMON case, since the
  # first-boot heredoc that writes this file never writes
  # POWERNODE_CA_LOCAL_DIR at all (only the LATER, separately-guarded
  # "publish" block in rails-start.sh does, and that block is
  # deliberately non-fatal on its own failure — e.g. ENOSPC on
  # /persist, named in its own comment). pipefail then propagates
  # grep's 1 through `cut`, killing THIS script before the very next
  # line runs — measured directly: the grep|cut form never reached the
  # line after it; sed did, with an empty value, exactly as intended.
  # sed with no match simply emits nothing and exits 0.
  #
  # tail -n1, not sed's own first-match: `. "$SECRETS_FILE"` (a REAL
  # shell source — what rails-start.sh and any out-of-band rails
  # process actually do) assigns whichever occurrence of the key comes
  # LAST when there's more than one (a file touched across several
  # boots/edits) — last-assignment-wins, not first. Matching that here
  # is what keeps this resolution identical to what the running
  # process actually resolves, instead of grep -m1's first-wins.
  # Anchor allows LEADING WHITESPACE and an optional `export ` prefix
  # (review round): `. "$SECRETS_FILE"` (a real shell source, what
  # rails-start.sh and any out-of-band rails process actually do)
  # accepts both `  POWERNODE_CA_LOCAL_DIR=...` and
  # `export POWERNODE_CA_LOCAL_DIR=...` as valid assignments — an
  # anchor pinned to column 1 with no export handling would silently
  # miss either shape (a hand-edited file is the realistic source of
  # both), leaving ca_local_dir empty, the real store never chowned,
  # and blocker 2's guard then turning that into a hard CaError.
  ca_local_dir="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?POWERNODE_CA_LOCAL_DIR=//p' \
    "$STATE_DIR/backend-default.conf" | tail -n1)"
  # Strip a pair of surrounding quotes if present — SINGLE as well as
  # DOUBLE (review round): `. `-sourced shell assignment strips either
  # (POWERNODE_CA_LOCAL_DIR='/some/path' is just as valid as the
  # double-quoted form), and a plain text sed extraction strips
  # neither. Left unstripped, the literal quote characters end up in
  # ca_local_dir, making `[ -d ]` false against a store that genuinely
  # exists and printing "no internal CA store yet" on a host that
  # actually has one.
  ca_local_dir="${ca_local_dir%\"}"
  ca_local_dir="${ca_local_dir#\"}"
  ca_local_dir="${ca_local_dir%\'}"
  ca_local_dir="${ca_local_dir#\'}"
fi
# `:=`, NOT a plain `=` (review round — say it explicitly so nobody
# "simplifies" this a fourth time): `readlink -m ""` is the ONE input
# that exits non-zero (verified: every other input, including a
# missing-parent path, exits 0) — `:=` substitutes the default on an
# EMPTY value too, not just an unset one, which is exactly what keeps
# that input unreachable. A bare `=` here would silently reopen
# blocker 1's whole failure class the moment ca_local_dir resolved to
# "" instead of staying unset.
: "${ca_local_dir:=$STATE_DIR/internal-ca}"
# Resolve through a symlink BEFORE testing/chowning (review round):
# `chown -R` does not descend through a symlink given as its own
# argument — it only re-owns the LINK itself, leaving whatever it
# points at untouched. A symlinked store (a deliberate operator
# layout) would silently get just the link chowned, and blocker 2's
# stricter EACCES-vs-absent guard would then turn the real directory's
# still-wrong ownership into a hard CaError instead of the old silent
# mint.
#
# `-m`, NOT `-f` (review round correction — measured, not assumed):
# readlink -f requires EVERY path component to exist and exits 1 the
# moment one doesn't; under set -euo pipefail that's blocker 1's exact
# failure class all over again — a boot-stopper, not a canonicalizer.
# Measured directly:
#   readlink -f /tmp/missing-leaf              -> exit 0 (parent exists)
#   readlink -f /tmp/missing-parent/x/ca       -> exit 1, kills the script
#   readlink -m /tmp/missing-parent/x/ca       -> exit 0, canonicalized
# This is reachable on more than an edge case: a stale/operator-set path
# whose parent no longer exists, OR any boot where the store's parent
# filesystem (e.g. /persist) simply isn't mounted yet when this script
# runs — /persist/powernode-internal-ca is exactly that shape. `-m`
# canonicalizes unconditionally (no component needs to exist) while
# still resolving a REAL symlink to its target, which is the only
# property this line actually needs — the `[ -d ]` test right after is
# what decides first-boot-vs-existing-store, not readlink's exit status.
ca_local_dir="$(readlink -m "$ca_local_dir")"
# Unconditional (review round): the success path used to print
# NOTHING, so a misresolved value (quoting bug, wrong symlink target)
# was invisible in the journal — only the failure branch spoke up.
echo "[rails-setup] internal CA store resolved to $ca_local_dir"
if [ -d "$ca_local_dir" ]; then
  chown -R "$RAILS_USER:$RAILS_USER" "$ca_local_dir"
else
  echo "[rails-setup] no internal CA store yet at $ca_local_dir — nothing to chown (first boot)"
fi

# LOUD BUT NON-FATAL: everything else under STATE_DIR (chiefly the
# vendored gem tree) gets the same ownership-fix sweep, but a failure on
# any ONE entry here must not stop the boot — none of this is on the
# secrets-regeneration path. Per-entry (not a single `-exec ... {} +`
# batch) specifically so a failure on one file doesn't cancel the whole
# batched invocation and so fixed/failed can be counted and reported.
fixed=0
failed=0
while IFS= read -r -d '' entry; do
  if chown "$RAILS_USER:$RAILS_USER" "$entry" 2>/dev/null; then
    fixed=$((fixed + 1))
  else
    failed=$((failed + 1))
    echo "[rails-setup] WARNING: could not fix ownership of $entry" >&2
  fi
done < <(find "$STATE_DIR" \( ! -user "$RAILS_USER" -o ! -group "$RAILS_USER" \) -print0)
# Unconditional (review round): "swept, nothing to fix" and "this sweep
# never ran" must not look identical in the journal — gating the echo on
# fixed/failed > 0 made a clean sweep silent, indistinguishable from the
# sweep having been skipped entirely.
echo "[rails-setup] STATE_DIR ownership sweep: fixed=$fixed failed=$failed"

# --- Agent PKI directory: grant TRAVERSAL, not LISTING (review round:
#     0750 on the PARENT was wider than the header comment claimed — group
#     read+execute lets rails LIST the whole agent state root, not just
#     traverse into pki/: modules/, assignment-lkg.json, boot-composed.json
#     (both 0644 already), state.json, boot-slot.json, hostname,
#     module-signing keys all become visible to a `ls`. 0710 (group --x,
#     no group-r) restricts the parent to "open a KNOWN path underneath
#     it", matching the 0701 pattern the agent's own two parent dirs
#     already use. The pki/ dir ITSELF stays 0750 — rails needs to list
#     it (open-by-known-name isn't enough when the caller doesn't already
#     know the exact filename it wants, e.g. ca-chain.crt vs a
#     differently-named chain file on a future layout change), and
#     everything IN pki/ that rails must never read (node.key,
#     tasks_state.json) stays 0600, unreadable regardless of the
#     directory's own mode. ---
if mountpoint -q /persist 2>/dev/null; then
  AGENT_PKI_PARENT=/persist/var/lib/powernode
else
  AGENT_PKI_PARENT=/var/lib/powernode
fi
AGENT_PKI_DIR="$AGENT_PKI_PARENT/pki"

if [ -d "$AGENT_PKI_PARENT" ]; then
  chgrp "$RAILS_USER" "$AGENT_PKI_PARENT" 2>/dev/null || true
  chmod 0710 "$AGENT_PKI_PARENT" 2>/dev/null || true
  if [ -d "$AGENT_PKI_DIR" ]; then
    chgrp "$RAILS_USER" "$AGENT_PKI_DIR" 2>/dev/null || true
    chmod 0750 "$AGENT_PKI_DIR" 2>/dev/null || true
  fi
else
  echo "[rails-setup] no agent PKI dir at $AGENT_PKI_PARENT — no enrolled mTLS material yet, skipping"
fi

# config/database.yml — see the header comment above re: build-time vs.
# here. Idempotent: only rendered when absent, exactly like the old
# runtime step, just root instead of the (formerly root) rails process.
if [ ! -f "$RAILS_DIR/config/database.yml" ]; then
  echo "[rails-setup] Rendering config/database.yml from template"
  cp "$RAILS_DIR/config/database.yml.example" "$RAILS_DIR/config/database.yml"
fi
# Never chowned to RAILS_USER: it's world-readable (root's default 644),
# and rails only ever READS it — no write access needed post-render.
chmod 644 "$RAILS_DIR/config/database.yml" 2>/dev/null || true

# --- Traefik ingress dirs: setgid so rails can write without any
#     capability or further root involvement (IMP-94977647c24c review:
#     prefer setgid over CAP_CHOWN or a runtime-root fallback).
#
#     Covers BOTH the live, tmpfs-backed /etc/traefik pair AND the durable
#     /persist/powernode-traefik mirror (blocker 3): the durable dir and
#     its dynamic/ sibling were previously untouched by this script and
#     verified live to be traefik:traefik 0755 — group-readable but NOT
#     group-WRITABLE, so a non-root rails (a traefik GROUP member, not the
#     traefik user) could read but never create/replace a file there,
#     e.g. mirror_host_login_durably's write into <durable>/dynamic. ---
if mountpoint -q /persist 2>/dev/null; then
  TRAEFIK_CERT_DIR=/persist/powernode-traefik/certs
else
  TRAEFIK_CERT_DIR=/var/lib/powernode-traefik/certs
fi
# Sibling of the cert dir, same derivation Core::IngressConfigWriter's own
# durable_dynamic_dir_for uses (parent-of-cert-dir + "dynamic") — kept as
# a SEPARATE step (not folded into the if/else above) so the block that
# actually derives TRAEFIK_CERT_DIR from the mountpoint check stays
# byte-identical to rails-start.sh's own copy (see
# spec/scripts/rails_setup_root_prep_spec.rb's cross-script consistency
# check) — two scripts computing the SAME cross-module path via
# differently-shaped code is exactly how they'd silently drift apart.
TRAEFIK_DURABLE_ROOT="$(dirname "$TRAEFIK_CERT_DIR")"
TRAEFIK_DURABLE_DYNAMIC_DIR="$TRAEFIK_DURABLE_ROOT/dynamic"

# review round (BLOCKER 2): this whole block used to run directly under
# the script's own `set -e` — a read-only or full /persist, or the
# durable root existing as a symlink where a directory was expected,
# would abort mkdir/chown/chmod HERE and take rails-setup.service to
# "failed" with RemainAfterExit=yes. rails's start_before dependency on
# it then renders Requires=+After=, so rails never starts at all —
# Restart=always can't rescue a dependency that never ran, and a problem
# that is purely ABOUT traefik's ingress dirs would then take down the
# entire backend. Isolated in a function called from an `if` so bash's
# -e-suspension-under-a-tested-command rule applies to the WHOLE body
# (see bash manual, "the shell does not exit... status is being tested
# by if"): a failure degrades to a loud warning and a zero exit instead.
# The two secrets `mv`s and the database.yml `cp` above stay OUTSIDE any
# such wrapping and fully fatal on purpose — falling through past a
# failed secrets migration must never look like "no secrets yet, generate
# fresh ones", which would rotate SECRET_KEY_BASE under a live database.
setup_traefik_ingress_dirs() {
  mkdir -p /etc/traefik/dynamic "$TRAEFIK_CERT_DIR" "$TRAEFIK_DURABLE_DYNAMIC_DIR" || return 1
  # 2775 on every directory in the tree, including the durable ROOT
  # itself (not just its certs/dynamic children): setgid on a PARENT
  # only propagates to things created UNDER it from here on — it does
  # nothing for the parent's own pre-existing group-write bit, so the
  # root dir needs the same explicit fix as its children.
  chown root:traefik "$TRAEFIK_DURABLE_ROOT" /etc/traefik/dynamic "$TRAEFIK_CERT_DIR" "$TRAEFIK_DURABLE_DYNAMIC_DIR" || return 1
  chmod 2775 "$TRAEFIK_DURABLE_ROOT" /etc/traefik/dynamic "$TRAEFIK_CERT_DIR" "$TRAEFIK_DURABLE_DYNAMIC_DIR" || return 1
}

if getent group traefik >/dev/null 2>&1; then
  if setup_traefik_ingress_dirs; then
    # Existing files from a prior ROOT-run boot (or, for the durable
    # mirror, from when it was solely traefik-owned) don't inherit the
    # setgid bit retroactively, and file-level permissions win over the
    # directory's — fix ownership/mode on whatever is already there;
    # setgid covers everything created from now on. Only reached once the
    # base setup above actually succeeded — fixing up files under dirs
    # that may not exist (or aren't owned right yet) isn't meaningful.
    find "$TRAEFIK_DURABLE_ROOT" /etc/traefik/dynamic -mindepth 1 -exec chown root:traefik {} \; 2>/dev/null || true
    find "$TRAEFIK_DURABLE_ROOT" /etc/traefik/dynamic -mindepth 1 -type d -exec chmod 2775 {} \; 2>/dev/null || true
    # blocker 5: mode split by CONTENT, not by directory — a single 660
    # pass over the whole tree hit core-self-signed.key (private key
    # material, wants 0640 to match Core::IngressConfigWriter's own
    # assert_key_group_and_mode!) and the dynamic YAML files (non-secret —
    # ensure_host_login_ingress! already chmods its OWN fresh write to
    # 0644) identically, at 0660 — wrong for both. *.key files get 0640;
    # everything else under the cert dirs (the cert itself, the internal-CA
    # bundle) gets 0640 too, since none of it needs world-read and matching
    # the key's mode keeps this pass simple. Dynamic YAML gets 0664
    # (group-write so a non-owner rails can replace it; world-read matches
    # the writer's own 0644 intent, widened only by the group-write bit).
    find "$TRAEFIK_CERT_DIR" -mindepth 1 -type f -exec chmod 0640 {} \; 2>/dev/null || true
    find /etc/traefik/dynamic "$TRAEFIK_DURABLE_DYNAMIC_DIR" -mindepth 1 -type f -exec chmod 0664 {} \; 2>/dev/null || true
  else
    echo "[rails-setup] WARNING: traefik ingress dir setup failed (read-only/full /persist? a symlink where a directory was expected?) — rails may be unable to write ingress config; continuing boot rather than taking the backend down over a traefik-ingress-only problem" >&2
  fi
else
  echo "[rails-setup] no 'traefik' group on this node (reverse-proxy-traefik not co-located) — skipping ingress dir setgid"
fi

echo "[rails-setup] done"
