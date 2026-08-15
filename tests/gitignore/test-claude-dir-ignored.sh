#!/usr/bin/env bash
# test-claude-dir-ignored.sh — regression guard for IMP-cad10660f674.
#
# This submodule's own .gitignore had no .claude/ entry, unlike the parent
# platform's .gitignore (which ignores .claude/worktrees/ and friends).
# Claude Code sessions leave .claude/worktrees/ full of complete agent
# worktree copies (embedded-repo gitlinks plus loose files) in the working
# tree. Without an ignore entry here, that stray tree shows as `?? .claude/`
# in exactly the git status every committer sees, and `git add -A` / `git
# add .` run inside this submodule stages it straight into the public
# powernode-system repo.
#
# This test asserts the submodule's .gitignore ignores .claude/ paths. It
# uses `git check-ignore` against synthetic paths (which does not require
# the path to actually exist on disk) so the assertion doesn't depend on a
# worktree incidentally being present at test time.
#
# Usage: bash tests/gitignore/test-claude-dir-ignored.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail
# (deliberately NOT -e: a failed assertion must not abort the remaining
# test cases — see assert_ignored below, which records failures instead of
# exiting.)

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

assert_ignored() {
  local path="$1"
  if git -C "$REPO_ROOT" check-ignore -q -- "$path"; then
    echo "PASS: '$path' is ignored"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: '$path' is NOT ignored (git add -A would stage it)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# A representative agent-worktree file — the concrete case that motivated
# this test.
assert_ignored ".claude/worktrees/agent-deadbeef/README.md"
# The worktree directory itself, so `git add -A` can't pick up the gitlink
# for a nested .git even when it has no files git considers interesting.
assert_ignored ".claude/worktrees/agent-deadbeef"
# Any other loose file directly under .claude/ — the fix ignores the whole
# directory, not just worktrees/.
assert_ignored ".claude/some-future-file"

echo
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
