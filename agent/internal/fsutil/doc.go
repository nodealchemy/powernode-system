// Package fsutil contains small filesystem helpers reused across the
// agent. Promoted from internal/dockerd + internal/k3sd in Phase 0 of
// the stub implementation plan so manifest, fleetevent, scripts, and
// the M2.D CLI commands can share the same atomic-write semantics.
//
// # Key primitives
//
// AtomicWrite(path, data, mode) writes data to a temp file in the same
// directory as path and renames it over the target. On Linux the rename
// is atomic: readers see either the old contents or the new, never a
// half-written file. AtomicWriteJSON(path, v, mode) marshals v and writes
// it the same way.
//
// Same-directory constraint: the temp file is created in
// filepath.Dir(path), so the rename never crosses a filesystem. os.Rename
// across filesystems fails with EXDEV; it never degrades to a copy.
// Neither helper creates the parent directory.
//
// # Sequence
//
// create temp → write → chmod → fsync → close → rename → fsync the parent
// directory (best effort, so the rename itself survives a crash)
//
// Any failure before the rename removes the temp file and leaves the
// target untouched. Behavior is preserved from the dockerd.atomicWrite
// call pattern; consolidating it here means every caller gets the same
// guarantees without copy-pasting fsync logic.
package fsutil
