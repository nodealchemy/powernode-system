#!/usr/bin/env bash
# verify-acme-binary.sh — fail-loud presence check for the powernode-acme binary a build is about
# to ship (IMP-fdc3b6a53d77).
#
# Acme::LegoClient shells out to this binary for every ACME issue/renew/revoke. It used to be
# built locally only (agent/Makefile), never staged, and the extension-system module masks
# agent/dist, so a built hub had no binary and every certificate operation raised at runtime —
# found by reading a hub, not by any build. This check runs against what is about to SHIP (the
# file in the staged rootfs), not the build output, so a stage that silently drops or clobbers it
# fails the BUILD instead of shipping a hollow layer.
#
# Usage: verify-acme-binary.sh PATH [--min-bytes N]
#
# Checks, each fatal (exit 2, message on stderr naming the path):
#   - PATH is a regular file and not a symlink (the usrmerge clobber class: stage15's agent arm
#     documents a `ln -sf` that replaced a real binary with a self-referential link);
#   - at least N bytes (default 1000000: a Go binary linking lego is many MB, so anything smaller
#     is a stub or an empty build);
#   - executable;
#   - `PATH version` — the binary's version subcommand; it has no --version flag — exits 0 and
#     prints JSON carrying a "version" field. It runs the binary for real, so a wrong-arch or
#     truncated file is caught here and not on the first renewal.
set -euo pipefail

die() {
  echo "verify-acme-binary.sh: FATAL: $*" >&2
  exit 2
}

[ $# -ge 1 ] || die "usage: verify-acme-binary.sh PATH [--min-bytes N]"
BIN="$1"; shift
MIN_BYTES=1000000
while [ $# -gt 0 ]; do
  case "$1" in
    --min-bytes)
      [ $# -ge 2 ] || die "--min-bytes requires an argument"
      MIN_BYTES="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ ! -L "$BIN" ] || die "$BIN is a symlink, not the shipped binary (usrmerge clobber?)"
[ -f "$BIN" ] || die "$BIN is missing or not a regular file — powernode-acme was not built into the layer"
size="$(stat -c%s "$BIN")"
[ "$size" -ge "$MIN_BYTES" ] || die "$BIN is only ${size} bytes (floor ${MIN_BYTES}) — a hollow build"
[ -x "$BIN" ] || die "$BIN is not executable"

# stdout only is judged; stderr is kept for the failure message, so a stderr line cannot satisfy
# the check. 30 s: the subcommand only prints build info, anything longer is a hang.
errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT
if ! out="$(timeout 30 "$BIN" version 2>"$errfile")"; then
  die "$BIN version failed: ${out:0:300} $(head -c 300 "$errfile")"
fi
[[ "$out" == *'"version"'* ]] || die "$BIN version printed no \"version\" field: ${out:0:300} $(head -c 300 "$errfile")"

echo "[verify-acme-binary] ok: $BIN ${size} bytes, $(printf '%s' "$out" | tr -d '\n' | cut -c1-200)"
