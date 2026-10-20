//go:build linux

package identity

import (
	"context"
	"errors"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

// sysMount mounts src at target read-only with nosuid/nodev/noexec. The flags
// come from the opts string the strategy passes (asserted in tests); only the
// fixed set is understood, anything else is refused rather than silently dropped.
func sysMount(ctx context.Context, src, target, fstype, opts, data string) error {
	if opts != mediaMountOpts {
		return syscall.EINVAL
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return syscall.Mount(src, target, fstype, syscall.MS_RDONLY|syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, data)
}

func sysUnmount(target string, detach bool) error {
	flags := 0
	if detach {
		flags = syscall.MNT_DETACH
	}
	return syscall.Unmount(target, flags)
}

const blkROSET = 0x125D // BLKROSET

// sysSetReadOnly flips the block device itself to read-only so not even a
// filesystem driver's journal replay can write to it.
func sysSetReadOnly(dev string) error {
	f, err := os.OpenFile(dev, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	one := int32(1)
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), blkROSET, uintptr(unsafe.Pointer(&one))); errno != 0 {
		return errno
	}
	return nil
}

// openBeneath opens rel below root without following any symlink: each
// directory component is opened with O_NOFOLLOW|O_DIRECTORY relative to the
// previous fd, the last with O_NOFOLLOW|O_NONBLOCK (so a FIFO cannot block).
func openBeneath(root, rel string) (*os.File, error) {
	fd, err := syscall.Open(root, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	parts := strings.Split(rel, "/")
	for i, p := range parts {
		if p == "" || p == "." || p == ".." {
			syscall.Close(fd)
			return nil, errors.New("bad path component")
		}
		flags := syscall.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
		if i < len(parts)-1 {
			flags |= syscall.O_DIRECTORY
		} else {
			flags |= syscall.O_NONBLOCK
		}
		next, err := syscall.Openat(fd, p, flags, 0)
		syscall.Close(fd)
		if err != nil {
			return nil, err
		}
		fd = next
	}
	return os.NewFile(uintptr(fd), rel), nil
}
