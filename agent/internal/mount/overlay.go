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

// EnsureUpperWorkDirs creates upperdir + workdir as tmpfs mounts.
// Idempotent: skip if already mounted.
func (o *Overlay) EnsureUpperWorkDirs(ctx context.Context) error {
	for _, p := range []string{o.Layout.UpperDir, o.Layout.WorkDir} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", p, err)
		}
		alreadyMounted, err := IsMountpoint(ctx, o.Runner, p)
		if err != nil {
			return err
		}
		if alreadyMounted {
			continue
		}
		// upper + work each get their own tmpfs so a write storm to one
		// doesn't pressure the other.
		if err := o.Runner.Run(ctx, "mount",
			"-t", "tmpfs",
			"-o", "size=512m,nosuid,nodev",
			"tmpfs-powernode", p,
		); err != nil {
			return err
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
		// Remount with new lowerdir (newer kernels support live remount;
		// fall through to umount+mount on failure).
		err := o.Runner.Run(ctx, "mount", "-o",
			"remount,lowerdir="+lowerdir+
				",upperdir="+o.Layout.UpperDir+
				",workdir="+o.Layout.WorkDir,
			o.Layout.SysRoot,
		)
		if err == nil {
			return nil
		}
		// Fallback: full umount + remount.
		if uerr := o.Runner.Run(ctx, "umount", o.Layout.SysRoot); uerr != nil {
			return fmt.Errorf("remount failed (%v) and umount fallback failed: %w", err, uerr)
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
