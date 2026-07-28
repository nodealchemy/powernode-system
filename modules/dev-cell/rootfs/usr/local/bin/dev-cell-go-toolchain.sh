#!/usr/bin/env bash
# Dev-cell: provision the Go toolchain onto /persist.
#
# WHY THIS EXISTS. Shipping platform updates from a dev-cell means running the
# verification gate before pushing, and a large part of the gate is the on-node
# agent's Go suite (`cd agent && go test ./...`). There is no `runtime-go`
# module in the catalog, and `/` is an ephemeral erofs+tmpfs overlay — anything
# apt-installed into the composed root is gone on the next recompose. So the
# toolchain is unpacked onto /persist once and picked up by
# /etc/profile.d/50-dev-cell-go.sh on every login thereafter.
#
# Mirrors dev-cell-clone.sh: idempotent, safe to re-run, and guarded by a
# ConditionPathExists=! in the unit so a normal boot skips it entirely.
#
# The version is taken from the agent's own go.mod (`go <version>` directive) so
# the toolchain tracks what the code actually requires instead of drifting; the
# `go` tool refuses to build when it is older than the directive. Falls back to
# a pinned floor when the checkout is not present yet (clone races this unit).
set -euo pipefail

WORK="${DEV_CELL_WORK:-/persist/home/pnadmin/work}"
DEST="${DEV_CELL_GO_ROOT:-/persist/dev/toolchain}"
FALLBACK_VERSION="${DEV_CELL_GO_FALLBACK:-1.25.0}"
OWNER="${DEV_CELL_GO_OWNER:-pnadmin}"

log() { printf '[dev-cell-go-toolchain] %s\n' "$*"; }

# Resolve the required version from agent/go.mod when the workspace is cloned.
required_version() {
    local gomod="$WORK/extensions/system/agent/go.mod"
    if [ -r "$gomod" ]; then
        local v
        v="$(awk '/^go [0-9]/ { print $2; exit }' "$gomod" 2>/dev/null || true)"
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    fi
    printf '%s' "$FALLBACK_VERSION"
}

WANT="$(required_version)"

# Already good enough? `go version` prints e.g. "go version go1.26.5 linux/amd64".
# Compare with sort -V so a NEWER toolchain than the directive is accepted —
# Go is backward compatible and the directive is a floor, not a pin.
if [ -x "$DEST/go/bin/go" ]; then
    have="$("$DEST/go/bin/go" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
    if [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$WANT" "$have" | sort -V | head -1)" = "$WANT" ]; then
        log "toolchain present: go$have (>= required go$WANT) — nothing to do"
        exit 0
    fi
    log "toolchain go${have:-unknown} is older than required go$WANT — replacing"
fi

# Resolve the concrete release. go.dev/VERSION reports the current stable, which
# is normally >= the directive; if it somehow is not, ask for the directive
# version explicitly rather than installing something too old.
stable="$(curl -fsSL -m 20 'https://go.dev/VERSION?m=text' 2>/dev/null | head -1 || true)"
stable="${stable#go}"
if [ -n "$stable" ] && [ "$(printf '%s\n%s\n' "$WANT" "$stable" | sort -V | head -1)" = "$WANT" ]; then
    version="$stable"
else
    version="$WANT"
fi

arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
tarball="go${version}.linux-${arch}.tar.gz"
log "installing go$version ($arch) into $DEST"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # expand $tmp now, not at trap time
trap "rm -rf '$tmp'" EXIT

curl -fsSL -m 600 -o "$tmp/go.tgz" "https://go.dev/dl/$tarball"

mkdir -p "$DEST"
# Unpack beside the live tree and swap, so an interrupted download never leaves
# a half-extracted toolchain that profile.d would then put on PATH.
rm -rf "$DEST/.go.new"
mkdir -p "$DEST/.go.new"
tar -C "$DEST/.go.new" -xzf "$tmp/go.tgz"
rm -rf "$DEST/go.old"
[ -d "$DEST/go" ] && mv "$DEST/go" "$DEST/go.old"
mv "$DEST/.go.new/go" "$DEST/go"
rm -rf "$DEST/.go.new" "$DEST/go.old"

# GOPATH/GOCACHE live beside the toolchain (profile.d points at them) so module
# and build caches survive recompose too — otherwise every boot re-downloads the
# module graph before the first `go test` can run.
mkdir -p "$DEST/../gopath" "$DEST/../gocache"
chown -R "$OWNER:$OWNER" "$DEST" "$DEST/../gopath" "$DEST/../gocache" 2>/dev/null || true

log "installed $("$DEST/go/bin/go" version 2>/dev/null || echo 'go (version unknown)')"
