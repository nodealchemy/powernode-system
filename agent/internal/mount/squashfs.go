package mount

import (
	"context"
	"fmt"
	"os"
)

// SquashfsMediaType is the OCI mediaType the platform uses when
// publishing a squashfs blob (see Phase 1.2 of the dual-format plan).
const SquashfsMediaType = "application/vnd.powernode.squashfs"

// MountModuleSquashfs mounts a module's squashfs image at the
// per-module path under l.ModulesMountRoot. Idempotent: returns nil
// if the mountpoint is already a squashfs mount.
//
// kernel mount syntax (overlayfs + squashfs, both upstream since 2.6.x):
//
//	mount -t squashfs -o loop,ro <sqfs-blob> <mountpoint>
//
// The kernel handles the loop device allocation automatically when the
// `loop` option is passed; no manual losetup needed. Read-only
// (-o ro) because the module artifact is content-addressed at
// publish time — any mutation would invalidate the fs-verity Merkle
// root the platform pinned at ingest.
//
// The squashfs blob is self-contained — no external CAS lookup like
// composefs has. That makes the per-module mountpoint larger on disk
// (~3x in our 8-module hub measurement) but gives universal kernel
// compatibility in exchange. See powernode.composefs_ubuntu_kernel_gap
// in MCP memory for the architectural decision context.
func MountModuleSquashfs(ctx context.Context, runner Runner, l Layout, m Module) error {
	mountpoint := l.ModuleMountPath(m.Digest)
	if err := os.MkdirAll(mountpoint, 0o755); err != nil {
		return fmt.Errorf("mkdir mountpoint %s: %w", mountpoint, err)
	}

	already, err := IsMountpoint(ctx, runner, mountpoint)
	if err != nil {
		return err
	}
	if already {
		return nil
	}

	sqfsPath := l.ModuleCachePath(m.Digest, "squashfs")
	if _, err := os.Stat(sqfsPath); err != nil {
		return fmt.Errorf("squashfs blob missing at %s — pull it before mounting: %w", sqfsPath, err)
	}

	return runner.Run(ctx, "mount",
		"-t", "squashfs",
		"-o", "loop,ro",
		sqfsPath,
		mountpoint,
	)
}

// UnmountModuleSquashfs reverses MountModuleSquashfs. Idempotent.
// Same shape as UnmountModule (composefs) — the kernel handles loop
// device teardown automatically when the squashfs mount is released.
func UnmountModuleSquashfs(ctx context.Context, runner Runner, l Layout, digest string) error {
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
