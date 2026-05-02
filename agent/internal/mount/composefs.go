package mount

import (
	"bytes"
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
// Uses `findmnt --noheadings` and inspects its stdout: non-empty output ⇒
// path is a mount, empty (or non-zero exit) ⇒ not a mount.
//
// Inspecting stdout (rather than the exit code via Runner.Run) makes the
// behavior trivially mockable via RecorderRunner — by default Output
// returns nil bytes for unstubbed commands, which naturally maps to
// "not a mountpoint". Tests that need to simulate "is mounted" populate
// StubOutput[findmnt-key] with a non-empty byte slice.
//
// findmnt returns exit 1 when not a mount; treating any non-success as
// "not mounted" is the right call here — real misconfig (findmnt missing,
// etc.) surfaces in subsequent mount/umount commands rather than this
// idempotency check.
func IsMountpoint(ctx context.Context, runner Runner, path string) (bool, error) {
	out, err := runner.Output(ctx, "findmnt", "--noheadings", path)
	if err != nil {
		return false, nil
	}
	return len(bytes.TrimSpace(out)) > 0, nil
}
