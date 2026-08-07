package runtime

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
)

// ErrScratchBudget marks a sync aborted because copying further files would
// leave the destination's backing filesystem (in production: the shared
// scratch tmpfs backing the live root's overlay upperdir — overlayfs statfs
// reports the upper fs) with less than SyncOptions.MinFreeBytes free.
// Callers match with errors.Is and surface "this recompose needs a
// (soft-)reboot" instead of letting the live root's upper hit ENOSPC
// mid-materialization.
var ErrScratchBudget = errors.New("scratch budget exhausted")

// freeBytesAt reports the free bytes available to unprivileged writers on
// the filesystem containing path. Package-level var so tests can inject a
// fake without a real small filesystem.
var freeBytesAt = func(path string) (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, err
	}
	return st.Bavail * uint64(st.Bsize), nil
}

// SyncOptions parameterizes SyncModuleFiles beyond the plain "copy this
// tree onto the root" contract.
type SyncOptions struct {
	// HigherLayers are the mounted trees of every module with HIGHER
	// effective priority than the module being synced, highest first —
	// the same order overlayfs resolves lowers in. A path any of these
	// provides is contested: the union serves the higher layer's entry,
	// so the sync must materialize THAT entry (or leave a live view that
	// already matches it alone), never this module's copy. Without this,
	// a low-priority module added or updated post-boot would copy-up its
	// version of a shared path and shadow the rightful winner until
	// reboot. Nil/empty means "this module wins every path it ships"
	// (correct only when the caller knows no higher layer exists).
	HigherLayers []string

	// MinFreeBytes, when > 0, enables the scratch budget guard: before
	// each file copy, the destination filesystem must have at least
	// (file size + MinFreeBytes) free or the sync aborts with
	// ErrScratchBudget. Files already copied stay — they are winner
	// content and re-converge on the next tick or reboot.
	MinFreeBytes uint64
}

// SyncResult counts what a sync did, for the caller's logging.
type SyncResult struct {
	// Changed counts files/symlinks actually written (new, or content/
	// target differed) — NOT directories, and not entries skipped as
	// already-identical.
	Changed int
	// Contested counts paths this module ships that a higher-priority
	// layer also ships (the higher layer's entry was kept/materialized).
	// Persistently non-zero means two modules are fighting over a path —
	// the same composition smell PruneResult.Restored surfaces.
	Contested int
}

// SyncModuleFilesToRoot preserves the original single-module contract:
// copy srcErofsDir onto dstRoot with no winner resolution and no budget
// guard. Thin wrapper over SyncModuleFiles — see its doc for the full
// contract.
func SyncModuleFilesToRoot(srcErofsDir, dstRoot string) (int, error) {
	res, err := SyncModuleFiles(srcErofsDir, dstRoot, SyncOptions{})
	return res.Changed, err
}

// SyncModuleFiles walks srcErofsDir (a module's loop-mounted,
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
//   - Deletions are NOT handled here — this function only ever adds or
//     overwrites. Removals are a separate pass with materially different
//     safety requirements (a path must be re-resolved against the
//     surviving layers before it can be unlinked, or the unlink punches
//     a whiteout through content the union should still serve), so they
//     live in hotprune.go and run immediately after this in
//     hotReconcileIfNeeded. Note the constraint that shapes both: the
//     old erofs tree is already unmounted by then, so the deletion pass
//     works from a path inventory captured before the detach loop
//     rather than from a live diff.
//   - Device nodes, FIFOs, and sockets (none expected in module content,
//     which is OS userland + application files) are skipped rather than
//     erroring.
//   - Never panics. Per-entry failures are collected and joined into the
//     returned error via errors.Join; the walk continues past them so one
//     bad entry doesn't block every other file in the module from
//     syncing.
//   - Contested paths (opts.HigherLayers): a path a higher-priority layer
//     also provides is materialized FROM that layer (findInLayers +
//     restoreFrom, the same resolution prune uses), never from this
//     module — the union winner must win in the live view too.
//   - Budget (opts.MinFreeBytes): each copy is preceded by a free-space
//     probe on dstRoot's filesystem; a would-breach copy aborts the whole
//     walk with ErrScratchBudget (already-copied files stay — they are
//     winner content either way).
func SyncModuleFiles(srcErofsDir, dstRoot string, opts SyncOptions) (SyncResult, error) {
	var res SyncResult
	var errs []error

	var guard func(int64) error
	if opts.MinFreeBytes > 0 {
		guard = func(size int64) error {
			free, ferr := freeBytesAt(dstRoot)
			if ferr != nil {
				// Fail open: a probe failure must not block a sync that
				// may well fit; ENOSPC on the actual copy still surfaces.
				return nil
			}
			if free < uint64(size)+opts.MinFreeBytes {
				return fmt.Errorf("%w: copying %d bytes would leave under the %d-byte floor (%d free)",
					ErrScratchBudget, size, opts.MinFreeBytes, free)
			}
			return nil
		}
	}

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

		// Winner resolution: a path a higher-priority layer also provides
		// is contested, and the union serves THAT layer's entry — so the
		// live view must get the winner's content (restoreFrom is
		// idempotent when it already does), never this module's copy.
		// Directories are exempt: they merge in the union, and MkdirAll
		// below cannot lose anyone's content.
		if len(opts.HigherLayers) > 0 && !d.IsDir() {
			if winSrc, winInfo, found := findInLayers(opts.HigherLayers, rel); found {
				res.Contested++
				wrote, resErr := restoreFrom(winSrc, target, winInfo, guard)
				if resErr != nil {
					errs = append(errs, fmt.Errorf("winner rewrite %s: %w", rel, resErr))
					if errors.Is(resErr, ErrScratchBudget) {
						return fs.SkipAll
					}
				} else if wrote {
					res.Changed++
				}
				return nil
			}
		}

		switch {
		case d.Type()&fs.ModeSymlink != 0:
			wrote, symErr := syncSymlink(path, target)
			if symErr != nil {
				errs = append(errs, fmt.Errorf("symlink %s: %w", rel, symErr))
			} else if wrote {
				res.Changed++
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
			wrote, copyErr := syncRegularFile(path, target, info.Mode().Perm(), guard)
			if copyErr != nil {
				errs = append(errs, fmt.Errorf("copy %s: %w", rel, copyErr))
				if errors.Is(copyErr, ErrScratchBudget) {
					return fs.SkipAll
				}
			} else if wrote {
				res.Changed++
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

	return res, errors.Join(errs...)
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
// actually happened. A non-nil guard is consulted with the source size
// after the identical-check and before any write — an identical file
// never charges the budget, and a guard refusal propagates verbatim so
// errors.Is(err, ErrScratchBudget) works at the caller.
func syncRegularFile(src, dst string, mode os.FileMode, guard func(int64) error) (bool, error) {
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
	if guard != nil {
		si, statErr := os.Stat(src)
		if statErr != nil {
			return false, fmt.Errorf("stat source: %w", statErr)
		}
		if gerr := guard(si.Size()); gerr != nil {
			return false, gerr
		}
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
