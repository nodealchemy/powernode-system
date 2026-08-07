//go:build linux

package mount

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// This file is the phase-3 primitive of the live-recompose ladder (see
// docs/operations/live-recompose-design-2026-08-06.md in the platform
// repo): ATOMIC replacement of a mounted union with a freshly composed one,
// with no file copying and no service interruption beyond the units whose
// content actually changed.
//
// It cannot replace / — every running process's root path pins the old
// root mount, so a beneath-swap of / would leave the whole system running
// on the detached old union forever. It exists for SUBMOUNTS (the
// systemd-sysext model: composition mounted at /usr, /opt, …), where
// lookups cross the mount table on every walk: the instant the swap lands,
// every process sees the new union, while open fds and running binaries
// keep the old inodes alive via the lazily-detached old mount until they
// close — ordinary deleted-file semantics.
//
// Mechanics (kernel >= 6.5, the release MOVE_MOUNT_BENEATH was merged in
// for exactly this systemd-sysext refresh use case; the noble base image
// runs 6.8):
//
//  1. fsopen("overlay") + fsconfig build the new union from the SAME
//     read-only erofs module mounts the live union uses — sharing lowers
//     between overlay mounts is fine, sharing upper/work is not.
//  2. fsmount produces a detached mount fd — the union exists, attached
//     nowhere.
//  3. move_mount(MOVE_MOUNT_BENEATH) slides it UNDER the mount currently
//     at the target; unmounting the old top (MNT_DETACH) then reveals it.
//     Between the two calls every lookup still atomically resolves to
//     exactly one complete union — old or new, never a mix.

// moveMountBeneath is MOVE_MOUNT_BENEATH from <linux/mount.h> (0x200,
// kernel >= 6.5). golang.org/x/sys v0.43.0 has not picked the constant up
// yet; drop the local copy once it does.
const moveMountBeneath = 0x200

// ComposeOverlayFD builds an overlay filesystem via the new mount API and
// returns a detached mount fd (close it with unix.Close when done; after a
// successful SwapBeneath the fd may also simply be closed).
//
// lowerDirs follows LowerDirString's convention: HIGHEST priority first
// (`lowerdir+` appends in the same order as the colon-separated string,
// first = union top). upperDir/workDir empty composes a READ-ONLY union of
// the lowers — the right shape for an immutable /usr prefix union; both
// must be set together for a writable one.
func ComposeOverlayFD(lowerDirs []string, upperDir, workDir string) (int, error) {
	if len(lowerDirs) == 0 {
		return -1, errors.New("ComposeOverlayFD: empty lower stack")
	}
	if (upperDir == "") != (workDir == "") {
		return -1, errors.New("ComposeOverlayFD: upperDir and workDir must be set together (or both empty for a read-only union)")
	}

	fsfd, err := unix.Fsopen("overlay", unix.FSOPEN_CLOEXEC)
	if err != nil {
		return -1, fmt.Errorf("fsopen overlay: %w", err)
	}
	defer unix.Close(fsfd)

	conf := func(key, val string) error {
		if cerr := unix.FsconfigSetString(fsfd, key, val); cerr != nil {
			return fmt.Errorf("fsconfig %s=%s: %w", key, val, cerr)
		}
		return nil
	}
	for _, low := range lowerDirs {
		// lowerdir+ takes ONE directory per call — that is the point of
		// the new API: no colon/comma escaping problems for paths the
		// string syntax cannot express.
		if err := conf("lowerdir+", low); err != nil {
			return -1, err
		}
	}
	if upperDir != "" {
		if err := conf("upperdir", upperDir); err != nil {
			return -1, err
		}
		if err := conf("workdir", workDir); err != nil {
			return -1, err
		}
	}
	// Match MountUnion's option set so the two compose paths cannot drift.
	if err := conf("redirect_dir", "on"); err != nil {
		return -1, err
	}
	if err := conf("metacopy", "on"); err != nil {
		return -1, err
	}

	if err := unix.FsconfigCreate(fsfd); err != nil {
		return -1, fmt.Errorf("fsconfig create: %w", err)
	}
	mfd, err := unix.Fsmount(fsfd, unix.FSMOUNT_CLOEXEC, 0)
	if err != nil {
		return -1, fmt.Errorf("fsmount: %w", err)
	}
	return mfd, nil
}

// SwapBeneath atomically replaces the mount currently at target with the
// detached mount fd (from ComposeOverlayFD): mounts it beneath the
// existing top, then lazily detaches the top. New lookups see the new
// mount from the moment the detach lands; existing open files keep the
// old one alive until released. The caller still owns mountFD.
func SwapBeneath(mountFD int, target string) error {
	if err := unix.MoveMount(mountFD, "", unix.AT_FDCWD, target,
		unix.MOVE_MOUNT_F_EMPTY_PATH|moveMountBeneath); err != nil {
		return fmt.Errorf("move_mount beneath %s: %w", target, err)
	}
	if err := unix.Unmount(target, unix.MNT_DETACH); err != nil {
		// The new union is mounted beneath but the old top still shadows
		// it — the system is consistent (still serving the old union),
		// but the swap has not landed. Surface loudly.
		return fmt.Errorf("detach old mount at %s (new union is staged beneath it): %w", target, err)
	}
	return nil
}

// KernelSupportsMoveMountBeneath reports whether the running kernel is at
// least 6.5 (where MOVE_MOUNT_BENEATH was merged). Callers preflight with
// this to fail with a clear message instead of EINVAL.
func KernelSupportsMoveMountBeneath() bool {
	var u unix.Utsname
	if err := unix.Uname(&u); err != nil {
		return false
	}
	return kernelAtLeast(unix.ByteSliceToString(u.Release[:]), 6, 5)
}

// kernelAtLeast parses "MAJ.MIN[.rest]" and compares. Unparseable
// releases report false — the caller then refuses with its clear message
// rather than guessing.
func kernelAtLeast(release string, wantMaj, wantMin int) bool {
	parts := strings.SplitN(release, ".", 3)
	if len(parts) < 2 {
		return false
	}
	maj, err := strconv.Atoi(parts[0])
	if err != nil {
		return false
	}
	minStr := parts[1]
	// Guard against suffixes like "6.5-rc1" when there is no third dot.
	if i := strings.IndexFunc(minStr, func(r rune) bool { return r < '0' || r > '9' }); i >= 0 {
		minStr = minStr[:i]
	}
	min, err := strconv.Atoi(minStr)
	if err != nil {
		return false
	}
	if maj != wantMaj {
		return maj > wantMaj
	}
	return min >= wantMin
}
