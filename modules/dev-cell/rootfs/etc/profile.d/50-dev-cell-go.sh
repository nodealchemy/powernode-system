# Dev-cell: put the /persist-backed Go toolchain on PATH for interactive shells.
#
# `/` is an ephemeral erofs+tmpfs overlay, so the toolchain cannot live in
# /usr/local — it is unpacked onto /persist by dev-cell-go-toolchain.service.
# This file is the other half: without it every shell would have to export
# PATH/GOPATH/GOCACHE by hand before running the agent's Go suite, which is
# exactly the manual step that made the verification gate unrunnable here.
#
# Sourced by every login shell, so it must never fail a login: no `set -e`, no
# unguarded commands, and every line is conditional on the toolchain actually
# being present (the unit may not have run yet on a first boot, or may have
# failed with no egress).

if [ -x /persist/dev/toolchain/go/bin/go ]; then
    case ":${PATH}:" in
        *":/persist/dev/toolchain/go/bin:"*) ;;
        *) PATH="/persist/dev/toolchain/go/bin:${PATH}" ;;
    esac
    export PATH

    # Keep module + build caches on /persist as well. Without these, GOPATH
    # defaults to ~/go and GOCACHE to ~/.cache/go-build — both under the
    # persisted home, which works, but splitting them out keeps the operator's
    # home small and makes the toolchain self-contained under /persist/dev.
    export GOPATH="${GOPATH:-/persist/dev/gopath}"
    export GOCACHE="${GOCACHE:-/persist/dev/gocache}"

    # GOTOOLCHAIN=auto (the default) will silently download a newer toolchain
    # into GOPATH when a go.mod names one. That is the behaviour we want here —
    # it keeps a stale on-disk toolchain from blocking a build — so it is left
    # alone deliberately rather than pinned to "local".
fi
