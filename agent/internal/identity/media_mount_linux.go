//go:build linux

package identity

import (
	"context"
	"syscall"
)

// sysMount mounts src at target read-only with nosuid/nodev/noexec. The flags
// come from the opts string the strategy passes (asserted in tests); only these
// four are understood, anything else is refused rather than silently dropped.
func sysMount(ctx context.Context, src, target, fstype, opts string) error {
	if opts != mediaMountOpts {
		return syscall.EINVAL
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return syscall.Mount(src, target, fstype, syscall.MS_RDONLY|syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, "")
}

func sysUnmount(target string) error { return syscall.Unmount(target, 0) }
