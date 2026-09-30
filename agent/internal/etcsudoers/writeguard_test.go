package etcsudoers

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// The default-target entry points resolve to /etc/sudoers.d — including the
// destructive ones (the sweep of powernode-* drop-ins, the break-glass
// removal). The guard must refuse them on the resolved path before any I/O.
func TestDefaultTargetsAreRefusedUnderTheGuard(t *testing.T) {
	calls := map[string]func() error{
		"Apply":                           func() error { return Apply(nil) },
		"ApplyOperatorBreakGlass(enable)": func() error { return ApplyOperatorBreakGlass(true) },
		"ApplyOperatorBreakGlass(revoke)": func() error { return ApplyOperatorBreakGlass(false) },
	}
	for name, call := range calls {
		var err error
		rec := writeguard.Capture(func() { err = call() })
		if err == nil || len(rec) != 1 {
			t.Errorf("%s: default target was not refused (err=%v, recorded=%d)", name, err, len(rec))
		}
	}
}

// F5: the directory passes, but a grant whose module name or id carries ".."
// renders to a path OUTSIDE it. The filename rule now refuses the grant before
// any path is built (so the guard is never reached, and Capture records
// nothing); no file may appear outside the sandbox either way.
func TestApplyAtRefusesAGrantThatEscapesItsDirectory(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "sudoers.d")
	// The sandbox for THIS spec is dir itself, so a file that lands in base is
	// outside it while the directory check on dir passes. Filename() is
	// "powernode-" + module + "-" + id; an id of "/../../evil" cancels the
	// prefix component and then climbs out of dir to <base>/evil.
	writeguard.Enable(dir)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { writeguard.Disable(); writeguard.Enable(os.TempDir()) })

	g := Grant{ModuleName: "a", Grant: manifest.ManifestSudoer{ID: "/../../evil", User: "u", RunasUser: "root", Commands: []string{"/bin/true"}}}
	var err error
	rec := writeguard.Capture(func() { err = ApplyAt([]Grant{g}, dir, staticClock()) })
	if err == nil {
		t.Fatalf("escaping grant was not refused: recorded=%v", rec)
	}
	if len(rec) != 0 {
		t.Errorf("the filename rule should refuse before the guard is reached; recorded %v", rec)
	}
	entries, _ := os.ReadDir(base)
	for _, e := range entries {
		if e.Name() != "sudoers.d" {
			t.Errorf("file %q written outside the sandbox dir", e.Name())
		}
	}
}
