#!/bin/bash
# dev-cell-clone.sh (`dev-cell-clone`) — one re-runnable command that stands up
# the operator's source workspace once his git key is registered with Gitea.
#
# Run as pnadmin (the operator). Idempotent + safe to re-run:
#   1. ensure the on-VM git key exists (dev-cell-git-keygen.sh);
#   2. verify the key is authorized on Gitea — if NOT, print the public key +
#      how to register it, and stop (no half-clone);
#   3. clone (or `git pull`) the platform repo + the system extension into
#      ~/work (persisted home on /persist), then `bundle` + `npm ci`.
#
# Everything runs as the operator — no root, no deploy key, no secrets handled
# here. The workspace lives in the operator's OWN persisted home (~/work), not
# the autonomous pnagent path (/persist/dev-cell/workspace), so the two never
# collide and the operator fully owns his tree.
set -euo pipefail

GIT_HOST="${DEV_CELL_GIT_HOST:-git.powernode.net}"
GIT_OWNER="${DEV_CELL_GIT_OWNER:-powernode}"
WORK="${DEV_CELL_WORK:-$HOME/work}"
# repo -> relative checkout path (extension repos nest under the platform tree,
# mirroring the DEV box layout). Space-separated "repo:path" pairs; overridable.
REPOS="${DEV_CELL_REPOS:-powernode-platform:. powernode-system:extensions/system}"

say() { echo "[dev-cell-clone] $*"; }

# --- 1. key present -----------------------------------------------------------
[ -f "$HOME/.ssh/id_ed25519" ] || /usr/local/bin/dev-cell-git-keygen.sh

# --- 2. is the key authorized on Gitea? --------------------------------------
# Gitea answers an SSH auth probe with "Hi <user>! You've successfully
# authenticated, but Gitea does not provide shell access." (exit 1, but that
# banner on stderr is the success signal). No banner => key not registered yet.
probe="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
          -T "git@${GIT_HOST}" 2>&1 || true)"
if ! printf '%s' "$probe" | grep -qiE 'successfully authenticated|does not provide shell'; then
  say "your git key is NOT yet authorized on ${GIT_HOST}."
  say "Add this PUBLIC key to Gitea (Settings -> SSH / GPG Keys), then re-run 'dev-cell-clone':"
  echo "-----8<----- PUBLIC KEY -----8<-----"
  cat "$HOME/.ssh/id_ed25519.pub"
  echo "-----8<----------------------8<-----"
  say "(probe said: ${probe})"
  exit 1
fi
say "git key authorized on ${GIT_HOST}."

# --- 3. clone / update + bundle + npm ----------------------------------------
mkdir -p "$WORK"
platform_dir=""
for pair in $REPOS; do
  repo="${pair%%:*}"; rel="${pair#*:}"
  dest="$WORK"; [ "$rel" = "." ] || dest="$WORK/$rel"
  url="git@${GIT_HOST}:${GIT_OWNER}/${repo}.git"
  [ "$repo" = "powernode-platform" ] && platform_dir="$dest"
  if [ -d "$dest/.git" ]; then
    say "updating $repo in $dest"
    git -C "$dest" pull --ff-only || say "WARN: '$repo' pull not fast-forward — leaving your working tree as-is"
  else
    say "cloning $repo -> $dest"
    mkdir -p "$(dirname "$dest")"
    git clone "$url" "$dest"
  fi
done

# Public GitHub submodules (anonymous https) — best-effort.
if [ -n "$platform_dir" ] && [ -f "$platform_dir/.gitmodules" ]; then
  say "initializing public submodules"
  git -C "$platform_dir" submodule update --init --recursive || say "WARN: submodule init incomplete"
fi

# bundle (server) — prefer the private Gemfile if present (business/system exts).
if [ -n "$platform_dir" ] && [ -d "$platform_dir/server" ]; then
  say "bundling (server)"
  if [ -f "$platform_dir/server/Gemfile.private" ]; then
    ( cd "$platform_dir/server" && BUNDLE_GEMFILE=Gemfile.private bundle install ) || say "WARN: private bundle incomplete"
  else
    ( cd "$platform_dir/server" && bundle install ) || say "WARN: bundle incomplete"
  fi
fi

# npm (frontend)
if [ -n "$platform_dir" ] && [ -f "$platform_dir/frontend/package.json" ]; then
  say "npm ci (frontend)"
  ( cd "$platform_dir/frontend" && npm ci ) || say "WARN: npm ci incomplete"
fi

say "workspace ready at $WORK. Next: cd $platform_dir/server && bin/rails db:migrate (dev DB already created)."
