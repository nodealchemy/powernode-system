#!/bin/bash
# dev-cell-validate-pnagent.sh — runs AS PNAGENT (via `runuser` from
# dev-cell-executor.sh, never standalone): restores the IMMUTABLE
# validator machinery from FETCH_HEAD (root's own `rootgit fetch` already
# populated .git/FETCH_HEAD with origin/develop, over the explicit,
# root-only clone_url — see dev-cell-executor.sh), runs
# scripts/validate.sh against that trusted copy, then restores the
# working tree back to exactly what's committed on HEAD (the loop
# branch). Exits with scripts/validate.sh's own exit code.
#
# C1 fix: every git invocation here goes through `pgit`, which disables
# hooks + attributes (core.hooksPath=/dev/null, core.attributesFile=
# /dev/null). pnagent already owns this repo, so a hook firing here is
# NOT a privilege escalation by itself — but a planted pre-checkout-ish
# hook or a smudge/clean filter could still silently rewrite the just-
# restored trusted content back to something tampered, defeating the
# entire point of this script without needing any escalation at all.
#
# H2 fix: the restore set is WIDER than just scripts/ .claude/
# .gitleaks.toml — it also covers the toolchain config
# scripts/validate.sh's own rspec/tsc invocations READ (server/.rspec,
# spec_helper.rb, rails_helper.rb, Gemfile.lock, .ruby-version,
# frontend/tsconfig*.json, package.json), so an agent can't neuter
# validation by editing THOSE instead of scripts/validate.sh itself (e.g.
# server/.rspec with a --pattern matching nothing -> 0 examples -> exit
# 0). Deliberately NOT restored: app/ and config/ (business logic,
# migrations, application config, and the spec/app files themselves) —
# those stay agent-authored so test-first work is actually exercised.
# This makes the loop-branch scripts/validate.sh run BEST-EFFORT, not a
# full guarantee — full assurance comes from the existing CI re-
# validation gate before the loop branch is ever merged into develop.
set -euo pipefail

WORKDIR="${DEV_CELL_WORKDIR:?DEV_CELL_WORKDIR not set — this script must be invoked by dev-cell-executor.sh, not run standalone}"

pgit() {
  git -C "$WORKDIR" -c core.hooksPath=/dev/null -c core.attributesFile=/dev/null "$@"
}

# Candidate paths to restore from FETCH_HEAD (develop). NOT included
# blindly — each is existence-checked against BOTH FETCH_HEAD and HEAD
# below before use. Two reasons this matters, both verified empirically:
#   1. git's multi-pathspec checkout/reset/clean ABORTS THE WHOLE COMMAND
#      if any single pathspec matches zero files in the target ref — and
#      whether these actually exist genuinely varies (server/.bundle/
#      config is gitignored, never tracked at all in this repo;
#      extensions/*/frontend/tsconfig.check.json depends on which
#      extensions are actually cloned — core mode vs. private-extension
#      mode).
#   2. A path present in FETCH_HEAD but absent from HEAD would abort the
#      LATER "restore to HEAD" step the same way — so candidates are only
#      used if they exist in BOTH refs, never just one.
CANDIDATE_PATHS=(
  scripts/
  .claude/
  .gitleaks.toml
  server/.rspec
  server/spec/spec_helper.rb
  server/spec/rails_helper.rb
  server/Gemfile.lock
  server/.bundle/config
  server/.ruby-version
  frontend/package.json
  frontend/tsconfig.json
  frontend/tsconfig.node.json
)

TREE_FETCH_HEAD=$(pgit ls-tree -r --name-only FETCH_HEAD)
TREE_HEAD=$(pgit ls-tree -r --name-only HEAD)

# $1=tree listing (one path per line), $2=candidate (dir or file,
# trailing slash optional). Exact match OR "is a directory prefix of some
# tracked file" — the same semantics `git checkout <pathspec>` itself
# uses for a directory argument.
path_exists_in() {
  local tree="$1" candidate="${2%/}" line
  while IFS= read -r line; do
    case "$line" in
      "$candidate") return 0 ;;
      "$candidate"/*) return 0 ;;
    esac
  done <<< "$tree"
  return 1
}

RESTORE_PATHS=()
for p in "${CANDIDATE_PATHS[@]}"; do
  if path_exists_in "$TREE_FETCH_HEAD" "$p" && path_exists_in "$TREE_HEAD" "$p"; then
    RESTORE_PATHS+=("$p")
  fi
done

# extensions/*/frontend/tsconfig.check.json — same existence-driven
# approach, discovered via a plain (non-glob) prefix pathspec on
# extensions/ + a bash-side filter: `git ls-tree` does not support
# :(glob) pathspec magic at all (verified empirically — "pathspec magic
# not supported by this command: 'glob'"), so a literal glob pathspec
# can't be used to enumerate these directly.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  path_exists_in "$TREE_HEAD" "$p" && RESTORE_PATHS+=("$p")
done < <(printf '%s\n' "$TREE_FETCH_HEAD" | grep -E '^extensions/[^/]+/frontend/tsconfig\.check\.json$' || true)

[ "${#RESTORE_PATHS[@]}" -gt 0 ] || { echo "dev-cell-validate-pnagent: no restore paths resolved in both FETCH_HEAD and HEAD — refusing to validate" >&2; exit 1; }

pgit checkout FETCH_HEAD -- "${RESTORE_PATHS[@]}"

cd "$WORKDIR"
set +e
bash scripts/validate.sh
STATUS=$?
set -e

# Restore the working tree to EXACTLY what's committed on HEAD (the loop
# branch). A plain `checkout HEAD -- <paths>` alone does NOT remove
# index/working-tree entries a FETCH_HEAD checkout added that HEAD
# doesn't have (verified empirically), hence the explicit reset+clean —
# same three-step dance dev-cell-executor.sh used before this fix, now
# run as pnagent instead of root.
pgit checkout HEAD -- "${RESTORE_PATHS[@]}"
pgit reset HEAD -- "${RESTORE_PATHS[@]}"
pgit clean -fdq -- "${RESTORE_PATHS[@]}"

exit "$STATUS"
