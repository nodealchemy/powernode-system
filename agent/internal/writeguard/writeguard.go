// Package writeguard is the test-time floor under the agent's host-global
// writers (etcidentity, etcsudoers): while a test binary has it enabled, any
// write whose RESOLVED path falls outside the sandbox root is refused and
// recorded, and the binary's exit status is forced non-zero.
//
// It exists because the writers default to the real /etc (and /home), the
// per-test override seams (ApplyAt, Paths, a root argument) are opt-in, and an
// opt-in seam a test forgets is silent until the day the suite runs as root on
// a real node — the same failure TestMain's other sandboxes were added for.
//
// The check is on the path, never on the write's outcome: unprivileged, the
// real /etc write fails with EACCES and looks harmless, so a guard keyed on
// the outcome would only ever fire for root.
//
// Production behaviour is unchanged: the guard is disabled unless a test
// binary's TestMain calls Run, a disabled Check is a no-op, and Enable/Run
// panic outside a test binary so production code can never arm it (an armed
// guard would refuse the real /etc/passwd render).
//
// Specs that provoke a violation on purpose consume it with Capture, which
// removes only the violations recorded inside its own call. There is no way to
// clear the whole record: a global reset would let a later spec erase an
// earlier test's swallowed violation and turn the binary green.
package writeguard

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

var (
	mu         sync.Mutex
	root       string // resolved sandbox root; "" means disabled
	violations []string

	// testingFn is a var so a spec can prove the production-arming refusal.
	testingFn = testing.Testing
)

// Run enables the guard rooted at os.TempDir(), runs the test binary via fn
// (normally m.Run), reports every surviving violation to stderr, and returns
// the exit code — non-zero when a violation was recorded even if every test
// passed, because a swallowed guard error would otherwise pass silently.
func Run(fn func() int) int {
	return run(fn, os.Stderr)
}

func run(fn func() int, stderr io.Writer) int {
	Enable(os.TempDir())
	defer Disable()
	code := fn()
	mu.Lock()
	v := violations
	violations = nil
	mu.Unlock()
	if len(v) > 0 {
		fmt.Fprintf(stderr, "writeguard: %d write(s) resolved outside the test sandbox:\n", len(v))
		for _, s := range v {
			fmt.Fprintln(stderr, "  "+s)
		}
		if code == 0 {
			code = 1
		}
	}
	return code
}

// Enable activates the guard with dir as the only writable root. It panics
// outside a test binary, and when dir is empty, relative, or resolves to "/" — a
// filesystem-wide sandbox would make the guard inert while looking armed.
func Enable(dir string) {
	if !testingFn() {
		panic("writeguard: Enable called outside a test binary")
	}
	r := resolve(dir)
	if dir == "" || !filepath.IsAbs(dir) || r == string(filepath.Separator) {
		panic(fmt.Sprintf("writeguard: sandbox root %q resolves to %q, which would allow every write", dir, r))
	}
	mu.Lock()
	defer mu.Unlock()
	root = r
}

// Disable deactivates the guard.
func Disable() {
	mu.Lock()
	defer mu.Unlock()
	root = ""
}

// Capture runs fn and returns, AND CONSUMES, the violations recorded while it
// ran; violations recorded before the call are untouched and still fail the
// binary. Specs use it to provoke a violation on purpose. Not for use from
// parallel tests: a violation another goroutine records inside the window is
// consumed too.
func Capture(fn func()) []string {
	mu.Lock()
	start := len(violations)
	mu.Unlock()
	fn()
	mu.Lock()
	defer mu.Unlock()
	if start > len(violations) {
		start = len(violations)
	}
	got := append([]string(nil), violations[start:]...)
	violations = violations[:start]
	return got
}

// Check reports whether a write to path may proceed. Disabled: always nil.
// Enabled: a relative path, or one that resolves (following every symlink,
// including a dangling final one, before any ".." is applied) outside the
// sandbox root, is recorded and returned as an error.
func Check(path string) error {
	mu.Lock()
	defer mu.Unlock()
	if root == "" {
		return nil
	}
	if !filepath.IsAbs(path) {
		return record("relative path %q (resolves against the working directory)", path)
	}
	if !within(root, resolve(path)) {
		return record("%q is outside the test sandbox %q", path, root)
	}
	return nil
}

// CheckHost is Check for a host-global effect with no path to inspect
// (sethostname(2)): while the guard is enabled every such effect is a
// violation, since no test may change the machine it runs on.
func CheckHost(effect string) error {
	mu.Lock()
	defer mu.Unlock()
	if root == "" {
		return nil
	}
	return record("host-global effect %q is not allowed in a test", effect)
}

// record must be called with mu held.
func record(format string, args ...any) error {
	msg := fmt.Sprintf(format, args...)
	violations = append(violations, msg)
	return fmt.Errorf("writeguard: %s", msg)
}

func within(dir, path string) bool {
	return path == dir || strings.HasPrefix(path, dir+string(filepath.Separator))
}

// maxLinks bounds symlink expansion (Linux's own limit is 40) so a loop fails
// closed rather than hanging the test binary.
const maxLinks = 40

// resolve returns where an ABSOLUTE path really points, walking it component by
// component so every symlink is followed BEFORE the next ".." is applied
// (lexically cleaning first would judge <sandbox>/link/../x by the sandbox, not
// by the link's target). A component that does not exist yet is taken as-is —
// the write is about to create it — and a dangling symlink is judged by its
// target, not by the directory it sits in. A loop or unreadable link resolves
// to "/", which is outside every valid sandbox.
func resolve(path string) string {
	sep := string(filepath.Separator)
	cur := sep
	work := strings.Split(path, sep)
	links := 0
	for len(work) > 0 {
		c := work[0]
		work = work[1:]
		switch c {
		case "", ".":
			continue
		case "..":
			cur = filepath.Dir(cur)
			continue
		}
		next := filepath.Join(cur, c)
		fi, err := os.Lstat(next)
		if err != nil || fi.Mode()&os.ModeSymlink == 0 {
			cur = next
			continue
		}
		if links++; links > maxLinks {
			return sep
		}
		target, err := os.Readlink(next)
		if err != nil {
			return sep
		}
		if filepath.IsAbs(target) {
			cur = sep
		}
		work = append(strings.Split(target, sep), work...)
	}
	return cur
}
