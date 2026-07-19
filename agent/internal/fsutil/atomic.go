// Package fsutil contains small filesystem helpers reused across the
// agent. Promoted from internal/dockerd + internal/k3sd in Phase 0 of
// the stub implementation plan so manifest, fleetevent, scripts, and
// the M2.D CLI commands can share the same atomic-write semantics.
package fsutil

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// AtomicWrite writes data to a sibling .tmp file in the same directory
// as path and renames over the target. On Linux this is atomic at the
// inode level — readers either see the old contents or the new, never
// a half-written file.
//
// Same-directory constraint: the temp file is created in
// filepath.Dir(path) so os.Rename stays a single-filesystem rename.
// Cross-filesystem renames degrade to copy+delete and lose atomicity.
//
// Behavior preserved verbatim from the dockerd.atomicWrite caller
// pattern: open temp → write → chmod → fsync → close → rename.
func AtomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".fsutil-*")
	if err != nil {
		return err
	}
	cleanup := func() { _ = os.Remove(tmp.Name()) }

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		cleanup()
		return err
	}
	// Best-effort parent-dir fsync so the rename itself is durable across a
	// crash. The temp file is already fsync'd and the rename is atomic within
	// the directory, but the directory ENTRY change (old name → new name) is
	// only guaranteed on disk after the dir is synced — otherwise a crash in the
	// window between rename and the kernel's implicit dir writeback can leave the
	// target absent on the next boot. Best-effort (ignore errors): it can only
	// improve durability, never regress a caller on a filesystem that doesn't
	// support directory fsync (the pre-rename behavior is preserved on failure).
	if d, derr := os.Open(dir); derr == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

// AtomicWriteJSON marshals v with encoding/json and writes the result
// atomically to path with the given mode. Convenience wrapper for the
// common case of persisting state files (k3sd_*_state.json,
// tasks_state.json, etc.).
//
// Caller is responsible for ensuring the parent directory exists —
// fsutil intentionally does NOT mkdir, mirroring AtomicWrite's
// single-responsibility contract.
func AtomicWriteJSON(path string, v any, mode os.FileMode) error {
	body, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("marshal json: %w", err)
	}
	return AtomicWrite(path, body, mode)
}
