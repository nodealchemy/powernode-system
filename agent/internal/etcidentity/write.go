package etcidentity

import (
	"fmt"
	"os"
	"syscall"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// PwdLockPath is the file glibc's lckpwdf() uses for advisory locking
// of the passwd database. flock(2) on this file gives us mutual
// exclusion with useradd/passwd/vipw without a cgo dependency — those
// tools all converge on this same lock under the hood.
const PwdLockPath = "/etc/.pwd.lock"

// LockTimeout matches glibc's lckpwdf() default (15 seconds). If we
// can't acquire the lock in that window, something is genuinely stuck
// and we should abort rather than wait forever.
const LockTimeout = 15 * time.Second

// Paths is the set of files Apply renders + the advisory lock file.
// Exported so callers (and tests) can override the target directory.
// Order matters for renders: passwd is written FIRST so any reader
// doing a passwd→shadow lookup during the lock window sees a
// consistent pair — even though we hold the lock for all four writes,
// defense in depth.
type Paths struct {
	Lock    string
	Passwd  string
	Group   string
	Shadow  string
	Gshadow string
}

// DefaultPaths returns the standard /etc/ paths. Tests override Lock
// to a tempdir-resident file so they can run without root + without
// contending with the real /etc/.pwd.lock that useradd/passwd hold.
func DefaultPaths() Paths {
	return Paths{
		Lock:    PwdLockPath,
		Passwd:  "/etc/passwd",
		Group:   "/etc/group",
		Shadow:  "/etc/shadow",
		Gshadow: "/etc/gshadow",
	}
}

// Apply writes the four identity files atomically under a single
// flock-protected critical section. Returns nil on full success; on
// partial failure (one of four writes fails), returns the error from
// the first failed write — the remaining files are NOT rolled back,
// but each individual file is at worst its prior consistent state
// (because AtomicWrite is atomic per-file). The next reconcile-tick
// retry will converge.
func Apply(set *Set) error {
	return ApplyAt(set, DefaultPaths())
}

// ApplyAt is Apply with overridable paths — used by tests to render
// into a tempdir rather than /etc.
func ApplyAt(set *Set, paths Paths) error {
	lockPath := paths.Lock
	if lockPath == "" {
		lockPath = PwdLockPath
	}
	unlock, err := acquireLock(lockPath, LockTimeout)
	if err != nil {
		return fmt.Errorf("acquire %s: %w", lockPath, err)
	}
	defer unlock()

	if err := fsutil.AtomicWrite(paths.Passwd, RenderPasswd(set), 0644); err != nil {
		return fmt.Errorf("write %s: %w", paths.Passwd, err)
	}
	if err := fsutil.AtomicWrite(paths.Group, RenderGroup(set), 0644); err != nil {
		return fmt.Errorf("write %s: %w", paths.Group, err)
	}
	if err := writeShadow(paths.Shadow, RenderShadow(set)); err != nil {
		return err
	}
	if err := writeShadow(paths.Gshadow, RenderGshadow(set)); err != nil {
		return err
	}
	return nil
}

// writeShadow writes a shadow-family file with 0640 root:root,
// matching the standard permissions glibc + sudo expect on
// /etc/shadow and /etc/gshadow.
func writeShadow(path string, data []byte) error {
	if err := fsutil.AtomicWrite(path, data, 0640); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	// AtomicWrite leaves the file owned by whoever ran the agent.
	// In production the agent runs as root so the chown is a no-op
	// over the existing owner; the explicit call is defense in depth
	// against a future agent that drops privileges. Skip when not
	// root — only root can chown, and tests should not require it.
	if os.Geteuid() != 0 {
		return nil
	}
	return os.Chown(path, 0, 0)
}

// acquireLock opens the lock file with O_CREAT|O_RDWR, then flock(2)s
// it LOCK_EX. Returns a release closure the caller defers. If LOCK_EX
// blocks longer than the supplied timeout, returns an error so the
// reconcile loop can fail this tick and try again later rather than
// pinning a goroutine indefinitely.
func acquireLock(path string, timeout time.Duration) (func(), error) {
	fd, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}

	// Try non-blocking first; fall back to a timed retry loop to honor
	// the timeout. syscall.Flock with LOCK_EX has no built-in deadline.
	deadline := time.Now().Add(timeout)
	for {
		err := syscall.Flock(int(fd.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() {
				_ = syscall.Flock(int(fd.Fd()), syscall.LOCK_UN)
				_ = fd.Close()
			}, nil
		}
		if err != syscall.EWOULDBLOCK {
			_ = fd.Close()
			return nil, err
		}
		if time.Now().After(deadline) {
			_ = fd.Close()
			return nil, fmt.Errorf("flock timeout after %s", timeout)
		}
		time.Sleep(100 * time.Millisecond)
	}
}
