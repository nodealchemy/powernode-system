#!/usr/bin/env bash
# assert-gemfile-lock-has-extension-path.sh — IMP-094d900f9093: fails the
# build loud when a Gemfile.lock does NOT declare the expected extension as
# a PATH gem.
#
# WHY THIS EXISTS: stage15.sh's powernode-hub-backend arm re-locks
# server/Gemfile.lock on the builder (to vendor an offline gem cache with
# `bundle cache --all-platforms`). That re-lock is genuinely NEEDED — core's
# own committed lock (rsynced in from the parent clone) carries a PATH
# section for every extension present in a normal core checkout, which is
# more than the hub actually composes, so re-locking is what drops the
# extensions the hub never runs. The bug was that the re-lock used to run
# WITHOUT extensions/system staged anywhere on the builder either, so
# Bundler's own discover_extension_gems_by_visibility
# (extensions_loader_helper.rb) found no extensions/ directory at all and
# dropped EVERY extension's PATH gem — including the one (system) the hub
# actually composes, not just the ones it doesn't. On a deployed hub
# (POWERNODE_DEPLOYED=1, extensions/system composed alongside this module)
# Bundler.setup then finds the Gemfile and the shipped lock disagreeing
# about the extension gem and rewrites the root-owned lock at BOOT, which
# needs CAP_DAC_OVERRIDE — a capability drop away from crash-looping on
# EACCES/EPERM on every boot.
#
# This script is the build-time assertion: run it against the lock AFTER
# the re-lock step, before it ships. A missing PATH section fails the BUILD
# here instead of surfacing as a boot-time crash loop on a deployed hub.
#
# Usage:
#   assert-gemfile-lock-has-extension-path.sh --lock FILE --gem NAME --remote REL_PATH
#
# Required:
#   --lock FILE       path to the Gemfile.lock to check
#   --gem NAME        the gem name expected inside the PATH stanza's specs
#                      (e.g. powernode_system)
#   --remote REL_PATH the PATH stanza's `remote:` value, EXACTLY as Bundler
#                      would render it (e.g. ../extensions/system/server)
#
# Exit: 2 on CLI misuse (missing/unknown flag, lock file not found) — same
# convention as stage-extension-system-files.sh's die(). 1 when the lock
# does not declare the expected PATH gem (the actual assertion failing) —
# 0 when it does.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: assert-gemfile-lock-has-extension-path.sh --lock FILE --gem NAME --remote REL_PATH
EOF
}

die() {
  echo "assert-gemfile-lock-has-extension-path.sh: error: $*" >&2
  exit 2
}

LOCK=""
GEM_NAME=""
REMOTE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --lock)
      [ $# -ge 2 ] || die "--lock requires an argument"
      LOCK="$2"; shift 2 ;;
    --gem)
      [ $# -ge 2 ] || die "--gem requires an argument"
      GEM_NAME="$2"; shift 2 ;;
    --remote)
      [ $# -ge 2 ] || die "--remote requires an argument"
      REMOTE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[ -n "$LOCK" ] || { usage >&2; die "--lock is required"; }
[ -n "$GEM_NAME" ] || { usage >&2; die "--gem is required"; }
[ -n "$REMOTE" ] || { usage >&2; die "--remote is required"; }
[ -f "$LOCK" ] || die "lock file not found: $LOCK"

# A PATH stanza looks like:
#   PATH
#     remote: ../extensions/system/server
#     specs:
#       powernode_system (0.1.0)
#         rails (~> 8.1)
#
# A Gemfile.lock can carry MULTIPLE PATH stanzas (one per extension); this
# walks each one independently and only trusts a match found INSIDE the
# stanza whose own remote: line matches, bounded by the next blank line
# (Bundler always blank-separates top-level stanzas) — so a gem name that
# merely appears as some OTHER stanza's dependency, or a remote: that
# merely appears in a comment, can never produce a false green.
FOUND=$(awk -v want_remote="  remote: $REMOTE" -v gem="$GEM_NAME" '
  /^PATH$/            { in_path = 1; remote_ok = 0; next }
  in_path && $0 == want_remote { remote_ok = 1; next }
  in_path && remote_ok && $0 ~ ("^    " gem " \\(") { print "found"; exit }
  /^$/                { in_path = 0; remote_ok = 0 }
' "$LOCK")

if [ "$FOUND" != "found" ]; then
  echo "assert-gemfile-lock-has-extension-path.sh: FATAL — $LOCK has no PATH section declaring $GEM_NAME at remote: $REMOTE. This lock would resolve CORE-ONLY on a deployed hub (POWERNODE_DEPLOYED=1, extensions/system composed alongside this module), and Bundler.setup rewriting the root-owned lock at boot needs CAP_DAC_OVERRIDE — with capabilities: [] that crash-loops on EACCES (IMP-094d900f9093)." >&2
  exit 1
fi

echo "assert-gemfile-lock-has-extension-path.sh: OK — $LOCK declares $GEM_NAME at remote: $REMOTE"
