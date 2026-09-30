package etcsudoers

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
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
	if err := writeguard.Check(dir); err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0750); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}

	kept := map[string]struct{}{}
	var firstWriteErr error
	// refused holds one RefusedGrantError per grant declined by the filename
	// rule, so an operator sees every bad grant rather than only the first.
	var refused []error

	// Name every grant BEFORE writing any. "-" is legal in both components, so
	// two DIFFERENT (module, id) identities can join to one basename; which one
	// won used to depend on input order, itself derived from Go map iteration
	// in the reconciler. Every identity in such a collision group is refused,
	// independent of order. The SAME identity arriving twice is not a
	// collision: the reconciler's old-union-new set legitimately carries a
	// grant from both manifests, and the later (the new manifest) wins by
	// being written last.
	type identity struct{ module, id string }
	paths := make([]string, len(grants))
	idsByPath := map[string]map[identity]struct{}{}
	for n, g := range grants {
		path, err := g.PathIn(dir)
		if err != nil {
			refused = append(refused, &RefusedGrantError{ModuleName: g.ModuleName, GrantID: g.Grant.ID, Reason: err.Error()})
			continue
		}
		paths[n] = path
		if idsByPath[path] == nil {
			idsByPath[path] = map[identity]struct{}{}
		}
		idsByPath[path][identity{g.ModuleName, g.Grant.ID}] = struct{}{}
	}

	for n, g := range grants {
		// paths[n] is empty for a grant the name rule already refused above:
		// nothing is rendered, written or removed for it, and the rest apply.
		path := paths[n]
		if path == "" {
			continue
		}
		if len(idsByPath[path]) > 1 {
			refused = append(refused, &RefusedGrantError{ModuleName: g.ModuleName, GrantID: g.Grant.ID,
				Reason: fmt.Sprintf("renders to %s, which another module/grant also renders to", g.Filename())})
			continue
		}
		if err := writeguard.Check(path); err != nil {
			if firstWriteErr == nil {
				firstWriteErr = err
			}
			continue
		}
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

	sweepErr := sweep(dir, kept)
	if firstWriteErr == nil && sweepErr == nil && len(refused) == 0 {
		return nil
	}
	return errors.Join(append(refused, firstWriteErr, sweepErr)...)
}

// sweep removes any /etc/sudoers.d/powernode-* file whose path is not
// in `kept`. Non-Powernode files (no powernode- prefix) are NEVER
// touched. The break-glass file (managed by ApplyOperatorBreakGlass
// independently of manifest-driven grants) is also excluded so the
// reconcile loop doesn't delete it between agent restarts.
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
		// Break-glass file is operator-controlled via env var, not
		// manifest-driven. Apply() doesn't know about it; only
		// ApplyOperatorBreakGlass does. Excluding here prevents the
		// reconcile loop from racing with the agent-startup write.
		if name == OperatorBreakGlassFilename {
			continue
		}
		// A ReadDir name cannot carry a separator, but the unlink still goes
		// through the same direct-child assertion as the writer. A present
		// powernode-* entry whose name would no longer validate (stale, or
		// inert to sudo because of a dot/tilde) is an ordinary orphan: it is
		// never in `kept`, so it is removed here, as a direct child only.
		path, err := childOf(dir, name)
		if err != nil {
			continue
		}
		if _, want := kept[path]; want {
			continue
		}
		if err := writeguard.Check(path); err != nil {
			return err
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("sweep %s: %w", path, err)
		}
	}
	return nil
}
