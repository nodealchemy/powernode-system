//go:build linux

package handlers

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// Every path below is ONE component resolved against a directory fd, never a
// joined string, and every open carries O_NOFOLLOW: a symlink planted at
// <unit>.d is refused (ELOOP) rather than followed to wherever it points, and
// a symlink planted at the target is refused before anything is renamed over
// it. unit and file are already confined to a single component by validateUnit
// and the name rule.

// openDropinDir opens root and then <unit>.d beneath it, creating the latter
// when create is set. It returns (-1, nil) when the directory does not exist
// and create is false.
func openDropinDir(root, unit string, create bool) (int, error) {
	rootfd, err := unix.Open(root, unix.O_PATH|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, fmt.Errorf("open %s: %w", root, err)
	}
	defer unix.Close(rootfd)

	dir := unit + ".d"
	if create {
		if err := unix.Mkdirat(rootfd, dir, 0o755); err != nil && !errors.Is(err, unix.EEXIST) {
			return -1, fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}
	dirfd, err := unix.Openat(rootfd, dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	switch {
	case err == nil:
		return dirfd, nil
	case errors.Is(err, unix.ENOENT) && !create:
		return -1, nil
	case errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR):
		return -1, taskguard.Refused("unit", "its drop-in directory is a symlink or not a directory", dir)
	default:
		return -1, fmt.Errorf("open %s: %w", dir, err)
	}
}

// existingRegular reports whether file exists in dirfd as a regular file, and
// refuses anything else sitting at that name (a symlink, a directory).
func existingRegular(dirfd int, file string) (bool, error) {
	var st unix.Stat_t
	err := unix.Fstatat(dirfd, file, &st, unix.AT_SYMLINK_NOFOLLOW)
	if errors.Is(err, unix.ENOENT) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("stat %s: %w", file, err)
	}
	if st.Mode&unix.S_IFMT != unix.S_IFREG {
		return false, taskguard.Refused("name", "the drop-in path holds a symlink or non-regular file", file)
	}
	return true, nil
}

// writeDropin writes content to <root>/<unit>.d/<file> atomically: a temp file
// in the same directory (O_CREAT|O_EXCL|O_NOFOLLOW), written, fsynced, then
// renamed over the target, and the directory fsynced. Any error before the
// rename removes the temp file, so the target is either the previous file or
// the new one, never a partial one. Reports whether a previous file was replaced.
func writeDropin(root, unit, file string, content []byte) (replaced bool, err error) {
	dirfd, err := openDropinDir(root, unit, true)
	if err != nil {
		return false, err
	}
	defer unix.Close(dirfd)

	if replaced, err = existingRegular(dirfd, file); err != nil {
		return false, err
	}

	suffix := make([]byte, 8)
	if _, err := rand.Read(suffix); err != nil {
		return false, err
	}
	tmp := "." + file + ".tmp-" + hex.EncodeToString(suffix)
	fd, err := unix.Openat(dirfd, tmp, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o644)
	if err != nil {
		return false, fmt.Errorf("create %s: %w", tmp, err)
	}
	f := os.NewFile(uintptr(fd), tmp)
	closed, committed := false, false
	defer func() {
		if !closed {
			_ = f.Close()
		}
		if !committed {
			_ = unix.Unlinkat(dirfd, tmp, 0)
		}
	}()

	if err := unix.Fchmod(fd, 0o644); err != nil {
		return false, fmt.Errorf("chmod %s: %w", tmp, err)
	}
	if err := dropinCheckFault("write"); err != nil {
		return false, err
	}
	if _, err := f.Write(content); err != nil {
		return false, fmt.Errorf("write %s: %w", tmp, err)
	}
	if err := dropinCheckFault("fsync"); err != nil {
		return false, err
	}
	if err := f.Sync(); err != nil {
		return false, fmt.Errorf("fsync %s: %w", tmp, err)
	}
	closed = true
	if err := f.Close(); err != nil {
		return false, fmt.Errorf("close %s: %w", tmp, err)
	}
	if err := dropinCheckFault("rename"); err != nil {
		return false, err
	}
	if err := unix.Renameat(dirfd, tmp, dirfd, file); err != nil {
		return false, fmt.Errorf("rename %s: %w", file, err)
	}
	committed = true
	_ = unix.Fsync(dirfd)
	return replaced, nil
}

// removeDropin unlinks <root>/<unit>.d/<file> and nothing else. Reports
// whether a file was removed; an absent directory or file is not an error.
func removeDropin(root, unit, file string) (bool, error) {
	dirfd, err := openDropinDir(root, unit, false)
	if err != nil || dirfd < 0 {
		return false, err
	}
	defer unix.Close(dirfd)

	var st unix.Stat_t
	err = unix.Fstatat(dirfd, file, &st, unix.AT_SYMLINK_NOFOLLOW)
	if errors.Is(err, unix.ENOENT) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("stat %s: %w", file, err)
	}
	if st.Mode&unix.S_IFMT == unix.S_IFDIR {
		return false, taskguard.Refused("name", "the drop-in path holds a directory", file)
	}
	// unlinkat never follows: a symlink at this name is removed as a link,
	// and its target is untouched.
	if err := unix.Unlinkat(dirfd, file, 0); err != nil {
		return false, fmt.Errorf("unlink %s: %w", file, err)
	}
	_ = unix.Fsync(dirfd)
	return true, nil
}

// fileOwnerUID is the owning uid from an Lstat result. An inode this cannot
// read an owner from counts as not root's.
func fileOwnerUID(_ string, fi os.FileInfo) uint32 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return st.Uid
	}
	return ^uint32(0)
}
