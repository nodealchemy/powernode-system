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
// binary's TestMain calls Run, and a disabled Check is a no-op.
package writeguard

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

var (
	mu         sync.Mutex
	root       string // resolved sandbox root; "" means disabled
	violations []string
)

// Run enables the guard rooted at os.TempDir(), runs the test binary via fn
// (normally m.Run), reports every recorded violation to stderr, and returns
// the exit code — non-zero when a violation was recorded even if every test
// passed, because a swallowed guard error would otherwise pass silently.
func Run(fn func() int) int {
	Enable(os.TempDir())
	code := fn()
	if v := Reset(); len(v) > 0 {
		fmt.Fprintf(os.Stderr, "writeguard: %d write(s) resolved outside the test sandbox:\n", len(v))
		for _, s := range v {
			fmt.Fprintln(os.Stderr, "  "+s)
		}
		if code == 0 {
			code = 1
		}
	}
	return code
}

// Enable activates the guard with dir as the only writable root. It is
// test-only by convention (see the package comment).
func Enable(dir string) {
	mu.Lock()
	defer mu.Unlock()
	root = resolve(dir)
}

// Disable deactivates the guard.
func Disable() {
	mu.Lock()
	defer mu.Unlock()
	root = ""
}

// Reset returns and clears the recorded violations. The guard's own specs use
// it to consume the violations they provoke on purpose.
func Reset() []string {
	mu.Lock()
	defer mu.Unlock()
	v := violations
	violations = nil
	return v
}

// Check reports whether a write to path may proceed. Disabled: always nil.
// Enabled: a relative path, or one that resolves (through symlinks on its
// deepest existing ancestor) outside the sandbox root, is recorded and
// returned as an error.
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

// resolve cleans path and resolves symlinks on its deepest existing ancestor,
// so a path that does not exist yet (the write is about to create it) is still
// judged by where its parent really lives.
func resolve(path string) string {
	path = filepath.Clean(path)
	rest := ""
	for p := path; ; p = filepath.Dir(p) {
		if real, err := filepath.EvalSymlinks(p); err == nil {
			return filepath.Join(real, rest)
		}
		if p == filepath.Dir(p) {
			return path
		}
		rest = filepath.Join(filepath.Base(p), rest)
	}
}
