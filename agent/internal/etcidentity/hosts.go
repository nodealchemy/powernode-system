package etcidentity

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// renderHosts renders a minimal, standard-shape /etc/hosts for a node whose
// hostname is name: loopback + the conventional Debian/Ubuntu 127.0.1.1 <name>
// line (so anything that resolves its own hostname via /etc/hosts, e.g. some
// Postgres/Rails boot-time hostname lookups, succeeds even with no DNS/mDNS),
// plus the standard ::1 line. Matches the shape of base-os's own static
// rootfs/etc/hosts (modules/base-os-ubuntu-noble) with the 127.0.1.1 line
// filled in — that file can't know the hostname at build time; this is the
// per-node reconcile it defers to.
func renderHosts(name string) []byte {
	var b bytes.Buffer
	fmt.Fprintf(&b, "127.0.0.1\tlocalhost\n")
	fmt.Fprintf(&b, "127.0.1.1\t%s\n", name)
	fmt.Fprintf(&b, "::1\tlocalhost ip6-localhost ip6-loopback\n")
	return b.Bytes()
}

// ApplyHosts makes <root>/etc/hosts authoritatively contain the loopback +
// 127.0.1.1 <name> lines for the node's hostname. It is the /etc/hosts
// analogue of ApplyHostname: same idempotence (a byte-identical file is a
// no-op so reconcile ticks never churn it), same atomic write, same root=""
// (live filesystem) vs root=<sysroot> (composed pivot union) semantics.
//
// Unlike ApplyHostname there is no "applyLive" mode — /etc/hosts has no
// kernel-side counterpart to sethostname(2); writing the file is the whole
// apply.
//
// Without this, a pivot node's union carries only base-os's static
// build-time /etc/hosts (127.0.0.1 localhost + ::1 — no per-node line,
// since base-os can't know the hostname at build time), which is already
// enough for "localhost" to resolve; this adds the 127.0.1.1 <name> line so
// anything resolving the node's OWN hostname via /etc/hosts also succeeds.
//
// name is trimmed of surrounding whitespace; an empty name is a no-op — this
// function never invents a hostname, mirroring ApplyHostname's contract (the
// caller owns sourcing the authoritative value).
//
// Returns (changed, error): changed is true when the file was actually
// mutated.
func ApplyHosts(root, name string) (changed bool, err error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return false, nil
	}
	if len(name) > HostNameMax {
		name = name[:HostNameMax]
	}

	path := "/etc/hosts"
	if root != "" {
		path = filepath.Join(root, "etc", "hosts")
	}

	want := renderHosts(name)
	if cur, rerr := os.ReadFile(path); rerr != nil || !bytes.Equal(cur, want) {
		if werr := fsutil.AtomicWrite(path, want, 0o644); werr != nil {
			return changed, fmt.Errorf("write %s: %w", path, werr)
		}
		changed = true
	}
	return changed, nil
}
