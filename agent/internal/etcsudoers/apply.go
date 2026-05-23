package etcsudoers

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// SudoersDir is the standard location for drop-in sudoers files on
// Debian/Ubuntu. Override via ApplyAt for tests.
const SudoersDir = "/etc/sudoers.d"

// ManagedPrefix is what marks a file as Powernode-managed. The sweep
// step removes orphaned files matching this prefix; non-Powernode
// files (operator-authored 90-admins, etc.) are never touched.
const ManagedPrefix = "powernode-"

// Apply renders, validates, and atomically writes one file per Grant
// under /etc/sudoers.d/, then sweeps any orphaned powernode-* files
// whose backing grant is gone.
//
// Each file is mode 0440 owned by root:root — the standard sudoers.d
// permissions. Any file whose visudo check fails is logged + skipped
// (the rest still get written); the agent surfaces the failure via
// its OnError hook so operators see the problem on the next reconcile.
func Apply(grants []Grant) error {
	return ApplyAt(grants, SudoersDir, time.Now)
}

// ApplyAt is Apply with overridable directory + clock — for tests.
func ApplyAt(grants []Grant, dir string, now func() time.Time) error {
	if err := os.MkdirAll(dir, 0750); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}

	kept := map[string]struct{}{}
	var firstWriteErr error

	for _, g := range grants {
		body := Render(g, now())
		if err := Validate(body); err != nil {
			// Skip this grant but keep going — one bad file shouldn't
			// invalidate every other module's sudo grants. The orphan
			// from a previous successful render gets swept below.
			if firstWriteErr == nil {
				firstWriteErr = fmt.Errorf("validate %s: %w", g.Filename(), err)
			}
			continue
		}
		path := filepath.Join(dir, g.Filename())
		if err := fsutil.AtomicWrite(path, body, 0440); err != nil {
			if firstWriteErr == nil {
				firstWriteErr = fmt.Errorf("write %s: %w", path, err)
			}
			continue
		}
		if err := os.Chown(path, 0, 0); err != nil {
			// Chown failure isn't fatal — file is still readable by
			// root, which is what sudo needs.
			_ = err
		}
		kept[path] = struct{}{}
	}

	if err := sweep(dir, kept); err != nil {
		if firstWriteErr == nil {
			return err
		}
	}

	return firstWriteErr
}

// sweep removes any /etc/sudoers.d/powernode-* file whose path is not
// in `kept`. Non-Powernode files (no powernode- prefix) are NEVER
// touched.
func sweep(dir string, kept map[string]struct{}) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, ManagedPrefix) {
			continue
		}
		path := filepath.Join(dir, name)
		if _, want := kept[path]; want {
			continue
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("sweep %s: %w", path, err)
		}
	}
	return nil
}
