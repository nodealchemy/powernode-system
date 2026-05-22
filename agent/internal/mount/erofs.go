// Package mount implements the agent's on-node read-only filesystem +
// overlayfs union machinery. Each platform module is published as a
// single erofs image (Enhanced Read-Only File System) and loop-mounted
// at attach time; the union of all attached modules forms /sysroot via
// overlayfs.
//
// erofs as the canonical lower-layer format:
//   - In Linux mainline since 5.4 (Nov 2019). Every distro we'd target
//     ships it enabled: Ubuntu 20.04+, Debian 11+, Rocky/Alma 9+,
//     Fedora 36+, Amazon Linux 2023, Alpine. No kernel-build choice
//     to negotiate the way composefs did.
//   - Production-proven on Android (default /system FS since 11),
//     ChromeOS, and Steam Deck.
//   - Native fs-verity integration, faster random-access reads than
//     squashfs, tail-packing + chunked layout deduplicate identical
//     content within one image.
//
// The earlier dual-format machinery (composefs + squashfs) was
// removed when we converged on erofs as the single canonical format.
// See powernode.composefs_ubuntu_kernel_gap in MCP memory for the
// decision context.
package mount

import (
	"bytes"
	"context"
	"fmt"
	"os"
)

// ErofsMediaType is the OCI mediaType the platform's CI workflow uses
// when pushing an erofs blob. The OciBlobProxyService reads this to
// find the right layer inside the OCI manifest.
const ErofsMediaType = "application/vnd.powernode.erofs"

// MountModule loop-mounts a module's erofs image at the per-module
// path under l.ModulesMountRoot. Idempotent — returns nil if the
// path is already an erofs mount.
//
// Mount syntax (universal since kernel 5.4):
//
//	mount -t erofs -o loop,ro <erofs-blob> <mountpoint>
//
// The kernel handles loop-device allocation automatically when `loop`
// is passed; no manual losetup. `ro` is redundant (erofs is read-only
// by design) but explicit + future-proofs against any rw-extension.
//
// The erofs blob is self-contained — no external CAS lookup. That
// keeps the publish pipeline simple (one blob per module) and makes
// the on-node disk layout trivially mappable: blob lives at
// /persist/cache/modules/<digest>.erofs, mount at
// /run/powernode/modules/<digest>.
func MountModule(ctx context.Context, runner Runner, l Layout, m Module) error {
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

	blobPath := l.ModuleCachePath(m.Digest)
	if _, err := os.Stat(blobPath); err != nil {
		return fmt.Errorf("erofs blob missing at %s — pull it before mounting: %w", blobPath, err)
	}

	return runner.Run(ctx, "mount",
		"-t", "erofs",
		"-o", "loop,ro",
		blobPath,
		mountpoint,
	)
}

// UnmountModule reverses MountModule. Idempotent. The kernel cleans up
// the loop device automatically when the mount is released.
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
// Inspecting stdout (rather than the exit code) makes the behavior
// trivially mockable via RecorderRunner — by default Output returns nil
// bytes for unstubbed commands, which naturally maps to "not a
// mountpoint". Tests that need to simulate "is mounted" populate
// StubOutput[findmnt-key] with a non-empty byte slice.
//
// findmnt returns exit 1 when not a mount; treating any non-success as
// "not mounted" is the right call — real misconfig (findmnt missing,
// etc.) surfaces in subsequent mount/umount commands rather than this
// idempotency check.
func IsMountpoint(ctx context.Context, runner Runner, path string) (bool, error) {
	out, err := runner.Output(ctx, "findmnt", "--noheadings", path)
	if err != nil {
		return false, nil
	}
	return len(bytes.TrimSpace(out)) > 0, nil
}
