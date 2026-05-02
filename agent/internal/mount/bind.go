package mount

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

// EnsurePersistentVar bind-mounts /persist/var onto /sysroot/var so the
// agent's runtime state (logs, databases, /var/lib/powernode/state.json)
// survives reboots while the rest of root stays ephemeral.
//
// Reference: Golden Eclipse plan — Hybrid persistent /var + ephemeral /
// upper-layer design (Decision 7).
func EnsurePersistentVar(ctx context.Context, runner Runner, l Layout) error {
	target := filepath.Join(l.SysRoot, "var")
	source := l.PersistentVarRoot

	for _, p := range []string{source, target} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", p, err)
		}
	}

	already, err := IsMountpoint(ctx, runner, target)
	if err != nil {
		return err
	}
	if already {
		return nil // bind already in place
	}

	return runner.Run(ctx, "mount", "--bind", source, target)
}

// UnmountPersistentVar reverses EnsurePersistentVar. Idempotent.
func UnmountPersistentVar(ctx context.Context, runner Runner, l Layout) error {
	target := filepath.Join(l.SysRoot, "var")
	already, err := IsMountpoint(ctx, runner, target)
	if err != nil {
		return err
	}
	if !already {
		return nil
	}
	return runner.Run(ctx, "umount", target)
}
