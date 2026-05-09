package mount

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Lock takes an exclusive flock on a sibling lockfile of path so the
// long-running service reconciler and CLI attach/detach commands can't
// race on state.json. Use a sidecar `<path>.lock` file rather than
// flocking state.json directly so atomic-rename doesn't drop the lock.
//
// Returns the unlock function which the caller MUST defer:
//
//	unlock, err := mount.Lock(mount.StatePath)
//	if err != nil { return err }
//	defer unlock()
//
// On Linux + macOS + BSD this uses syscall.Flock under the hood. Locks
// are released automatically if the process dies (kernel-side cleanup),
// so a crashed CLI doesn't strand a lock for the service to wait on
// indefinitely.
func Lock(path string) (func() error, error) {
	if path == "" {
		return nil, errors.New("mount.Lock: empty path")
	}
	lockPath := path + ".lock"

	if err := os.MkdirAll(filepath.Dir(lockPath), 0o755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", filepath.Dir(lockPath), err)
	}

	// O_CREATE|O_RDWR ensures the file exists; we never write to it.
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open lock file %s: %w", lockPath, err)
	}

	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("flock %s: %w", lockPath, err)
	}

	unlock := func() error {
		// LOCK_UN is best-effort — if it fails, closing the fd will
		// release the lock anyway (Linux kernel releases on last close).
		// Return the close error since that's the durable signal.
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		return f.Close()
	}
	return unlock, nil
}
