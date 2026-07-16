package runtime

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

// SyncModuleFilesToRoot walks srcErofsDir (a module's loop-mounted,
// read-only erofs blob at Layout.ModuleMountPath(digest)) and copies every
// entry into dstRoot (the live pivot-node root, "/"), so a changed module's
// new files show up WITHOUT a reboot.
//
// Why this exists: on a pivot node / IS the boot-time composed overlay
// union (see lifecycle.PivotAwareRootMode / RootModeNative), and the
// reconcile loop deliberately never re-extends /'s lowerdir post-boot (see
// the union-skip block in RunOnce) — a second overlay sharing the live
// root's upperdir/workdir is undefined kernel behavior, and extending the
// existing union's lowerdir isn't something overlayfs supports live at
// all. So when a module's content changes post-boot, its new files never
// land in / until a reboot — only its systemd units hot-restart, against
// whatever's still on disk. This function closes that gap by copying the
// files directly: any write under a mounted overlayfs's merged view is a
// copy-up onto the writable upperdir that shadows the read-only erofs
// lower automatically, no special overlay API required.
//
// Contract:
//   - Directories are created (MkdirAll) using the source directory's mode.
//     An already-existing destination directory is left as-is (MkdirAll
//     does not chmod existing dirs — matches `mkdir -p` semantics).
//   - Regular files are copied atomically: streamed into a temp file in
//     the SAME target directory, chmod'd to the source file's mode
//     (preserving the executable bit — a replaced binary must stay
//     0755), fsync'd, then renamed over the destination. A service
//     reading the destination path concurrently always observes either
//     the fully-old or fully-new file, never a partial write — critical
//     when the file being replaced is a running service's own binary.
//     We stream via io.Copy (not fsutil.AtomicWrite, which takes an
//     in-memory []byte) so a large module binary isn't fully buffered in
//     process memory; the temp+chmod+fsync+rename sequence mirrors
//     fsutil.AtomicWrite's atomicity guarantee.
//   - Symlinks are recreated verbatim via os.Symlink — never followed or
//     dereferenced. A destination that's already the correct symlink is
//     left untouched.
//   - Already-identical destination entries (same size, same content
//     hash) are skipped entirely — no temp file, no rename — so repeat
//     calls (e.g. a reconcile tick where nothing actually changed on
//     disk despite a digest bump) are cheap and don't spam the caller's
//     changed count.
//   - Deletions are OUT OF SCOPE for v1: if the new module version
//     dropped a file the old one shipped, the stale copy is left in
//     dstRoot untouched. Most module updates add or modify files rather
//     than remove them, and detecting a removal requires diffing the
//     old and new erofs trees (we only have the new one mounted here) —
//     left for a follow-up.
//   - Device nodes, FIFOs, and sockets (none expected in module content,
//     which is OS userland + application files) are skipped rather than
//     erroring.
//   - Never panics. Per-entry failures are collected and joined into the
//     returned error via errors.Join; the walk continues past them so one
//     bad entry doesn't block every other file in the module from
//     syncing.
//
// changed counts files/symlinks actually written (new, or content/target
// differed from what was already at the destination) — NOT directories,
// and not entries skipped as already-identical. Callers use changed > 0 to
// decide whether the hot-reconcile is worth surfacing.
func SyncModuleFilesToRoot(srcErofsDir, dstRoot string) (int, error) {
	changed := 0
	var errs []error

	walkErr := filepath.WalkDir(srcErofsDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			errs = append(errs, fmt.Errorf("walk %s: %w", path, err))
			return nil // one unreadable entry shouldn't abort the whole sync
		}

		rel, relErr := filepath.Rel(srcErofsDir, path)
		if relErr != nil {
			errs = append(errs, fmt.Errorf("rel %s: %w", path, relErr))
			return nil
		}
		if rel == "." {
			return nil // srcErofsDir itself maps to dstRoot, which already exists
		}
		target := filepath.Join(dstRoot, rel)

		switch {
		case d.Type()&fs.ModeSymlink != 0:
			wrote, symErr := syncSymlink(path, target)
			if symErr != nil {
				errs = append(errs, fmt.Errorf("symlink %s: %w", rel, symErr))
			} else if wrote {
				changed++
			}

		case d.IsDir():
			info, statErr := d.Info()
			if statErr != nil {
				errs = append(errs, fmt.Errorf("stat dir %s: %w", rel, statErr))
				return nil
			}
			if mkErr := os.MkdirAll(target, info.Mode().Perm()); mkErr != nil {
				errs = append(errs, fmt.Errorf("mkdir %s: %w", rel, mkErr))
			}

		case d.Type().IsRegular():
			info, statErr := d.Info()
			if statErr != nil {
				errs = append(errs, fmt.Errorf("stat %s: %w", rel, statErr))
				return nil
			}
			wrote, copyErr := syncRegularFile(path, target, info.Mode().Perm())
			if copyErr != nil {
				errs = append(errs, fmt.Errorf("copy %s: %w", rel, copyErr))
			} else if wrote {
				changed++
			}

		default:
			// Device node, FIFO, socket, or similar — not expected in
			// module content. Skip silently rather than error.
		}
		return nil
	})
	if walkErr != nil {
		errs = append(errs, fmt.Errorf("walk %s: %w", srcErofsDir, walkErr))
	}

	return changed, errors.Join(errs...)
}

// syncSymlink recreates the symlink at src (read via os.Readlink, never
// followed) at dst. No-ops if dst is already a symlink pointing at the
// same target. Returns wrote=true only when dst was actually created or
// repointed.
func syncSymlink(src, dst string) (bool, error) {
	linkTarget, err := os.Readlink(src)
	if err != nil {
		return false, fmt.Errorf("readlink source: %w", err)
	}

	if fi, statErr := os.Lstat(dst); statErr == nil {
		if fi.Mode()&os.ModeSymlink != 0 {
			if existing, rlErr := os.Readlink(dst); rlErr == nil && existing == linkTarget {
				return false, nil // already correct — idempotent no-op
			}
		} else if fi.IsDir() {
			return false, errors.New("destination is a directory, refusing to replace with a symlink")
		}
		// Wrong-target symlink or a plain file sitting at dst: remove so
		// os.Symlink (which refuses to overwrite anything) can recreate it.
		if rmErr := os.Remove(dst); rmErr != nil {
			return false, fmt.Errorf("remove existing: %w", rmErr)
		}
	} else if !os.IsNotExist(statErr) {
		return false, fmt.Errorf("lstat destination: %w", statErr)
	}

	if mkErr := os.MkdirAll(filepath.Dir(dst), 0o755); mkErr != nil {
		return false, fmt.Errorf("mkdir parent: %w", mkErr)
	}
	if symErr := os.Symlink(linkTarget, dst); symErr != nil {
		return false, fmt.Errorf("symlink: %w", symErr)
	}
	return true, nil
}

// syncRegularFile copies src to dst atomically (temp file in dst's
// directory, chmod'd to mode, fsync'd, renamed over dst) unless the two
// are already byte-identical. Returns wrote=true only when a copy
// actually happened.
func syncRegularFile(src, dst string, mode os.FileMode) (bool, error) {
	identical, err := filesIdentical(src, dst)
	if err != nil {
		return false, fmt.Errorf("compare: %w", err)
	}
	if identical {
		return false, nil
	}
	if fi, statErr := os.Lstat(dst); statErr == nil && fi.IsDir() {
		return false, errors.New("destination is a directory, refusing to replace with a file")
	}

	dir := filepath.Dir(dst)
	if mkErr := os.MkdirAll(dir, 0o755); mkErr != nil {
		return false, fmt.Errorf("mkdir parent: %w", mkErr)
	}

	in, err := os.Open(src)
	if err != nil {
		return false, fmt.Errorf("open source: %w", err)
	}
	defer in.Close()

	tmp, err := os.CreateTemp(dir, ".powernode-hotsync-*")
	if err != nil {
		return false, fmt.Errorf("create temp: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }

	if _, err := io.Copy(tmp, in); err != nil {
		_ = tmp.Close()
		cleanup()
		return false, fmt.Errorf("copy contents: %w", err)
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		cleanup()
		return false, fmt.Errorf("chmod: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		cleanup()
		return false, fmt.Errorf("fsync: %w", err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return false, fmt.Errorf("close temp: %w", err)
	}
	if err := os.Rename(tmpName, dst); err != nil {
		cleanup()
		return false, fmt.Errorf("rename: %w", err)
	}
	return true, nil
}

// filesIdentical reports whether a (the source, always expected to exist)
// and b (the destination, may not exist yet) have identical content. A
// missing or size-mismatched b short-circuits to false without hashing;
// only a size match triggers a full content hash comparison, so a changed
// file is detected cheaply while an unchanged one still gets a real
// (not just size/mtime-based) confirmation — mtimes on a freshly loop-
// mounted erofs blob aren't a meaningful signal of content equality.
func filesIdentical(a, b string) (bool, error) {
	ai, err := os.Stat(a)
	if err != nil {
		return false, fmt.Errorf("stat source: %w", err)
	}
	bi, err := os.Stat(b)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("stat destination: %w", err)
	}
	if bi.IsDir() {
		return false, nil // caller treats this as a conflict, not identity
	}
	if ai.Size() != bi.Size() {
		return false, nil
	}

	ah, err := hashFile(a)
	if err != nil {
		return false, fmt.Errorf("hash source: %w", err)
	}
	bh, err := hashFile(b)
	if err != nil {
		return false, fmt.Errorf("hash destination: %w", err)
	}
	return ah == bh, nil
}

// hashFile returns the raw SHA256 digest bytes (as a string) of path's
// content. Used only for equality comparison, never surfaced — raw bytes
// avoid the pointless hex-encode/decode round trip.
func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return string(h.Sum(nil)), nil
}
