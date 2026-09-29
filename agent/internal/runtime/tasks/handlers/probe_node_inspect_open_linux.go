//go:build linux

package handlers

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

// inspectOpenBeneath opens rel (a clean, symlink-free path RELATIVE to root, as
// resolved and judged by inspectFileStat) for reading with openat2(2),
// RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS.
//
// O_NOFOLLOW alone guards only the LAST component. Between the path being
// resolved and judged and this open, an intermediate directory can be swapped
// for a symlink (or the final file for one) and a plain open would follow it
// out of the allowed set. openat2 makes the kernel refuse, atomically and for
// every component, any symlink and any escape from root, so there is no window
// left to race and nothing to re-verify afterwards. The alternative, opening
// and then comparing readlink(/proc/self/fd/N) with the resolved path, detects
// a swap only after the open and depends on /proc; openat2 is available on
// every kernel this agent already requires (5.6, against the 6.5 its live
// recompose needs).
//
// O_NONBLOCK keeps a path swapped to a FIFO from blocking the open.
func inspectOpenBeneath(root, rel string) (*os.File, error) {
	dirfd, err := unix.Open(root, unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	defer unix.Close(dirfd)

	fd, err := unix.Openat2(dirfd, rel, &unix.OpenHow{
		Flags:   unix.O_RDONLY | unix.O_NONBLOCK | unix.O_CLOEXEC,
		Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_MAGICLINKS,
	})
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), rel), nil
}

// inspectOpenRaced reports whether an openat2 failure means the path CHANGED
// under the check (a symlink appeared, a component left the tree or turned into
// something else) rather than an ordinary I/O failure.
func inspectOpenRaced(err error) bool {
	return errors.Is(err, unix.ELOOP) || errors.Is(err, unix.EXDEV) ||
		errors.Is(err, unix.ENOTDIR) || errors.Is(err, unix.ENOENT)
}
