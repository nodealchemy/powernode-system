package etcidentity

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// Every default-target entry point must be refused by the guard BEFORE any I/O:
// the verdict is on the resolved path, so these are safe (and meaningful) run
// unprivileged, and would be equally safe as root. The sandboxed arm of each
// is already covered by the package's own tests, which all pass a tempdir.
func TestDefaultTargetsAreRefusedUnderTheGuard(t *testing.T) {
	calls := map[string]func() error{
		"Apply":         func() error { return Apply(&Set{}) },
		"ApplyHostname": func() error { _, err := ApplyHostname("", "guard-probe", false); return err },
		"ApplyHostname live": func() error {
			// A sandboxed root whose file write succeeds, so the ONLY thing
			// left to refuse is the host-global sethostname(2).
			root := t.TempDir()
			if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
				t.Fatal(err)
			}
			_, err := ApplyHostname(root, "guard-probe-live", true)
			return err
		},
		"ApplyHosts":           func() error { _, err := ApplyHosts("", "guard-probe"); return err },
		"EnsureTraversableDir": func() error { return EnsureTraversableDir("/home") },
		"EnsureOwnedDir":       func() error { return EnsureOwnedDir("/home/guard-probe", 0, 0, 0o700) },
		"ReconcileHomeOwnership": func() error {
			// Reconcile does its own Check (it no longer routes through the
			// two helpers above); a warn is its only error channel.
			var got error
			set := &Set{Users: []User{{Name: "probe", UID: 0, PrimaryGID: 0, Home: "/home/guard-probe"}}}
			ReconcileHomeOwnership(set, "", func(_ string, err error) { got = err })
			return got
		},
	}
	for name, call := range calls {
		var err error
		rec := writeguard.Capture(func() { err = call() })
		if err == nil || len(rec) != 1 {
			t.Errorf("%s: default/out-of-sandbox target was not refused (err=%v, recorded=%d)", name, err, len(rec))
		}
	}
}
