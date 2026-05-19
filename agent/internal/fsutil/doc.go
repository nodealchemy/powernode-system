// Package fsutil contains small filesystem helpers reused across the
// agent. Promoted from internal/dockerd + internal/k3sd in Phase 0 of
// the stub implementation plan so manifest, fleetevent, scripts, and
// the M2.D CLI commands can share the same atomic-write semantics.
//
// # Key primitive
//
// AtomicWrite(path, data, mode) — writes data to a sibling .tmp file in
// the same directory as path and renames over the target. On Linux this
// is atomic at the inode level: readers either see the old contents or
// the new, never a half-written file.
//
// Same-directory constraint: the temp file lives in filepath.Dir(path)
// so os.Rename stays a single-filesystem rename. Cross-filesystem
// renames degrade to copy+delete and lose atomicity, so the helper
// refuses to span filesystems.
//
// # Sequence
//
// open temp → write → chmod → fsync → close → rename
//
// Behavior is preserved verbatim from the dockerd.atomicWrite call
// pattern; consolidating it here means every caller gets the same
// guarantees without copy-pasting fsync logic.
package fsutil
