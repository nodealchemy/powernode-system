package mount

import (
	"context"
	"fmt"
	"os"
)

// MountModule mounts a single module's composefs metadata image at the
// per-module path under l.ModulesMountRoot. Idempotent: returns nil if
// the path is already a composefs mount.
//
// composefs mount syntax (kernel >= 6.6):
//
//	mount -t composefs <metadata-image> <mountpoint> -o basedir=<digest-store>
//
// The digest store is a single CAS directory shared across all modules
// on this node — it's the fs-verity-anchored content. The metadata image
// is module-specific and points into the store.
func MountModule(ctx context.Context, runner Runner, l Layout, m Module) error {
	mountpoint := l.ModuleMountPath(m.Digest)
	if err := os.MkdirAll(mountpoint, 0o755); err != nil {
		return fmt.Errorf("mkdir mountpoint %s: %w", mountpoint, err)
	}

	// Skip if already mounted (idempotency).
	already, err := IsMountpoint(ctx, runner, mountpoint)
	if err != nil {
		return err
	}
	if already {
		return nil
	}

	cfsPath := l.ModuleCachePath(m.Digest)
	if _, err := os.Stat(cfsPath); err != nil {
		return fmt.Errorf("composefs blob missing at %s — pull it before mounting: %w", cfsPath, err)
	}

	store := l.DigestStorePath()
	return runner.Run(ctx, "mount",
		"-t", "composefs",
		"-o", "basedir="+store,
		cfsPath,
		mountpoint,
	)
}

// UnmountModule reverses MountModule. Idempotent.
func UnmountModule(ctx context.Context, runner Runner, l Layout, digest string) error {
	mountpoint := l.ModuleMountPath(digest)
	already, err := IsMountpoint(ctx, runner, mountpoint)
	if err != nil {
		return err
	}
	if !already {
		return nil
	}
	return runner.Run(ctx, "umount", mountpoint)
}

// IsMountpoint returns true if the given path is currently a mount point.
// Uses `findmnt` (cheap, returns nonzero if not a mount).
func IsMountpoint(ctx context.Context, runner Runner, path string) (bool, error) {
	err := runner.Run(ctx, "findmnt", "--noheadings", path)
	if err == nil {
		return true, nil
	}
	// findmnt returns exit 1 when not a mount; differentiating from a
	// real error is awkward through Run's combined-error wrapper, so
	// we treat any non-success as "not mounted" here. Real misconfig
	// (findmnt missing, etc.) will surface in subsequent commands.
	return false, nil
}
