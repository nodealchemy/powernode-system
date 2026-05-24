package mount

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
)

// Overlay is the agent's high-level handle for the union mount.
type Overlay struct {
	Layout Layout
	Runner Runner
}

// LowerDirString returns the overlayfs `lowerdir=` argument for a sorted
// ModuleStack. overlayfs lower order is HIGHEST-priority FIRST (gets
// merged top-down), which is the reverse of SortByPriority's ascending
// output, so we reverse before joining.
func LowerDirString(layout Layout, stack ModuleStack) string {
	sorted := stack.SortByPriority()
	parts := make([]string, 0, len(sorted))
	for i := len(sorted) - 1; i >= 0; i-- {
		parts = append(parts, layout.ModuleMountPath(sorted[i].Digest))
	}
	return strings.Join(parts, ":")
}

// EnsureUpperWorkDirs mounts a single shared tmpfs at ScratchRoot
// and creates upper + work as direct subdirectories.
//
// overlayfs's kernel-side check requires upperdir and workdir to
// reside under the SAME mount — not just the same filesystem.
// Bind-mounting two paths from one tmpfs doesn't satisfy this; the
// kernel treats bind mounts as distinct mount points. So the only
// layout that works is one tmpfs mount whose subdirectories are
// upper + work.
//
// Idempotent: skips the mount if ScratchRoot is already a mount point.
func (o *Overlay) EnsureUpperWorkDirs(ctx context.Context) error {
	scratch := o.Layout.ScratchRoot
	if scratch == "" {
		return errors.New("EnsureUpperWorkDirs: Layout.ScratchRoot is empty (Layout not initialized?)")
	}
	if err := os.MkdirAll(scratch, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", scratch, err)
	}
	scratchMounted, err := IsMountpoint(ctx, o.Runner, scratch)
	if err != nil {
		return err
	}
	if !scratchMounted {
		// size applies to upper + work pooled; in practice upper is
		// the only thing that grows, work just holds overlayfs
		// whiteout state.
		if err := o.Runner.Run(ctx, "mount",
			"-t", "tmpfs",
			"-o", "size=512m,nosuid,nodev,mode=755",
			"tmpfs-powernode-scratch", scratch,
		); err != nil {
			return fmt.Errorf("mount scratch tmpfs at %s: %w", scratch, err)
		}
	}
	for _, sub := range []string{o.Layout.UpperDir, o.Layout.WorkDir} {
		if err := os.MkdirAll(sub, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", sub, err)
		}
	}
	return nil
}

// MountUnion assembles the overlayfs at l.SysRoot. Each Module in stack
// is expected to already be composefs-mounted at its per-module path
// (call MountModule for each first).
func (o *Overlay) MountUnion(ctx context.Context, stack ModuleStack) error {
	if len(stack) == 0 {
		return errors.New("MountUnion: empty module stack")
	}
	if err := o.EnsureUpperWorkDirs(ctx); err != nil {
		return err
	}
	if err := os.MkdirAll(o.Layout.SysRoot, 0o755); err != nil {
		return fmt.Errorf("mkdir sysroot %s: %w", o.Layout.SysRoot, err)
	}
	lowerdir := LowerDirString(o.Layout, stack)

	already, err := IsMountpoint(ctx, o.Runner, o.Layout.SysRoot)
	if err != nil {
		return err
	}
	if already {
		// overlayfs `mount -o remount,lowerdir=...` is a kernel no-op:
		// the syscall returns success but lowerdir is set at mount time
		// and cannot be replaced (only the upperdir/workdir/ro-rw flags
		// can be flipped at remount, plus `lowerdir+=` to APPEND on
		// 5.18+). Replacing the lowerdir stack requires a fresh mount,
		// so we always umount + remount when /sysroot is already up.
		//
		// Lazy umount (`-l`, MNT_DETACH) is the safe fallback for the
		// busy case: a service that holds /sysroot open (e.g. a unit
		// still in `activating auto-restart`) keeps its existing
		// references to the old union, while new accesses see the new
		// one. Existing references drop when the process exits.
		if uerr := o.Runner.Run(ctx, "umount", o.Layout.SysRoot); uerr != nil {
			if lerr := o.Runner.Run(ctx, "umount", "-l", o.Layout.SysRoot); lerr != nil {
				return fmt.Errorf("umount %s failed (%v) and lazy umount fallback failed: %w",
					o.Layout.SysRoot, uerr, lerr)
			}
		}
	}

	return o.Runner.Run(ctx, "mount",
		"-t", "overlay", "overlay",
		"-o", "lowerdir="+lowerdir+
			",upperdir="+o.Layout.UpperDir+
			",workdir="+o.Layout.WorkDir+
			",redirect_dir=on,metacopy=on",
		o.Layout.SysRoot,
	)
}

// UnmountUnion tears down the overlay. Idempotent.
func (o *Overlay) UnmountUnion(ctx context.Context) error {
	already, err := IsMountpoint(ctx, o.Runner, o.Layout.SysRoot)
	if err != nil {
		return err
	}
	if !already {
		return nil
	}
	return o.Runner.Run(ctx, "umount", o.Layout.SysRoot)
}
