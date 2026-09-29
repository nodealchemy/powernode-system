package writeguard

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// enableFor arms the guard for one spec and disarms it afterwards. Any
// violation still recorded at cleanup is a spec bug (it should have used
// Capture), so it is dropped here rather than leaking into the binary's exit.
func enableFor(t *testing.T, dir string) {
	t.Helper()
	Enable(dir)
	t.Cleanup(func() { Disable(); drop() })
}

// drop clears the record; test-only, so production code has no way to do it.
func drop() {
	mu.Lock()
	defer mu.Unlock()
	violations = nil
}

// The guard is only proven by both arms: it must FIRE on an out-of-sandbox
// path and PASS on an in-sandbox one, and it must do so unprivileged (the
// verdict is on the path, so no /etc write is ever attempted here).
func TestCheck(t *testing.T) {
	sandbox := t.TempDir()
	enableFor(t, sandbox)

	outside := t.TempDir() // a second, unrelated root standing in for /etc
	link := filepath.Join(sandbox, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	// A dangling link whose TARGET (not its parent) is outside the sandbox.
	dangling := filepath.Join(sandbox, "dangling")
	if err := os.Symlink(filepath.Join(outside, "not-yet"), dangling); err != nil {
		t.Fatal(err)
	}
	// A link that stays inside, so following it must still pass.
	if err := os.Mkdir(filepath.Join(sandbox, "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	inlink := filepath.Join(sandbox, "inlink")
	if err := os.Symlink(filepath.Join(sandbox, "real"), inlink); err != nil {
		t.Fatal(err)
	}
	// A relative link whose ".." climbs out of the sandbox.
	relout := filepath.Join(sandbox, "relout")
	if err := os.Symlink("../..", relout); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name string
		path string
		bad  bool
	}{
		{"sandbox file, not yet created", filepath.Join(sandbox, "etc", "passwd"), false},
		{"sandbox root itself", sandbox, false},
		{"symlink that stays inside", filepath.Join(inlink, "x"), false},
		{"real etc passwd", "/etc/passwd", true},
		{"real sudoers.d", "/etc/sudoers.d", true},
		{"sibling of the sandbox", outside, true},
		{"dotdot escape", filepath.Join(sandbox, "..", "elsewhere"), true},
		{"relative path", "etc/passwd", true},
		{"symlink out of the sandbox", filepath.Join(link, "passwd"), true},
		// F3: the ".." must apply to the link's TARGET, not lexically to the
		// sandbox. sb/escape/../x is <outside>/../x, not <sandbox>/x.
		{"symlink then dotdot", sandbox + "/escape/../x", true},
		{"dangling final symlink to outside", dangling, true},
		{"dangling final symlink child", filepath.Join(dangling, "child"), true},
		{"relative symlink climbing out", filepath.Join(relout, "x"), true},
	}
	for _, c := range cases {
		var err error
		rec := Capture(func() { err = Check(c.path) })
		if got := err != nil; got != c.bad {
			t.Errorf("%s: Check(%q) error=%v, want violation=%v", c.name, c.path, err, c.bad)
		}
		if got := len(rec) > 0; got != c.bad {
			t.Errorf("%s: recorded=%v, want %v", c.name, got, c.bad)
		}
	}
}

func TestSymlinkLoopFailsClosed(t *testing.T) {
	sandbox := t.TempDir()
	enableFor(t, sandbox)
	a, b := filepath.Join(sandbox, "a"), filepath.Join(sandbox, "b")
	if err := os.Symlink(b, a); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(a, b); err != nil {
		t.Fatal(err)
	}
	var err error
	Capture(func() { err = Check(filepath.Join(a, "x")) })
	if err == nil {
		t.Fatal("a symlink loop must fail closed")
	}
}

func TestCheckHostFiresOnlyWhenEnabled(t *testing.T) {
	Disable()
	if err := CheckHost("sethostname"); err != nil {
		t.Fatalf("disabled guard must be a no-op, got %v", err)
	}
	enableFor(t, t.TempDir())
	var err error
	rec := Capture(func() { err = CheckHost("sethostname") })
	if err == nil || len(rec) != 1 {
		t.Fatalf("enabled guard must refuse a host-global effect and record it: err=%v rec=%v", err, rec)
	}
}

func TestDisabledIsNoOp(t *testing.T) {
	Disable()
	var err error
	rec := Capture(func() { err = Check("/etc/passwd") })
	if err != nil || len(rec) != 0 {
		t.Fatalf("disabled guard must not refuse or record: err=%v rec=%v", err, rec)
	}
}

func TestRunForcesNonZeroOnAViolationEvenWhenTestsPass(t *testing.T) {
	t.Cleanup(func() { Disable(); drop() })
	var out bytes.Buffer
	code := run(func() int {
		_ = Check("/etc/passwd")
		return 0
	}, &out)
	if code == 0 {
		t.Fatal("Run returned 0 despite a recorded violation")
	}
	out.Reset()
	if code := run(func() int { return 0 }, &out); code != 0 || out.Len() != 0 {
		t.Fatalf("clean run: code=%d out=%q", code, out.String())
	}
}

// F1: a spec that consumes ITS OWN violation with Capture must not erase one an
// earlier test recorded and swallowed. Sort order used to decide whether the
// binary exited 0.
func TestCaptureLeavesEarlierViolationsStanding(t *testing.T) {
	t.Cleanup(func() { Disable(); drop() })
	var out bytes.Buffer
	code := run(func() int {
		_ = Check("/etc/earlier-swallowed") // an earlier test, error ignored
		got := Capture(func() { _ = Check("/etc/own-provoked") })
		if len(got) != 1 || !strings.Contains(got[0], "own-provoked") {
			t.Errorf("Capture returned %v", got)
		}
		return 0
	}, &out)
	if code == 0 {
		t.Fatal("the earlier test's violation was erased; the binary would exit 0")
	}
	if !strings.Contains(out.String(), "earlier-swallowed") || strings.Contains(out.String(), "own-provoked") {
		t.Fatalf("report should list only the surviving violation, got %q", out.String())
	}
}

// F4: a sandbox that resolves to "/" (or is empty/relative) allows every path,
// so the guard would look armed while being inert. Enable must refuse it.
func TestEnableRefusesAnInertSandbox(t *testing.T) {
	t.Cleanup(Disable)
	for _, dir := range []string{"", "/", "relative/dir"} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("Enable(%q) did not panic", dir)
				}
			}()
			Enable(dir)
		}()
	}
	// A symlink to "/" resolves to "/" as well.
	link := filepath.Join(t.TempDir(), "rootlink")
	if err := os.Symlink("/", link); err != nil {
		t.Fatal(err)
	}
	func() {
		defer func() {
			if recover() == nil {
				t.Error("Enable(symlink to /) did not panic")
			}
		}()
		Enable(link)
	}()
}

// F6: production code must not be able to arm the guard.
func TestEnableAndRunPanicOutsideATestBinary(t *testing.T) {
	orig := testingFn
	testingFn = func() bool { return false }
	t.Cleanup(func() { testingFn = orig; Disable() })
	for name, call := range map[string]func(){
		"Enable": func() { Enable(t.TempDir()) },
		"Run":    func() { Run(func() int { return 0 }) },
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("%s did not panic outside a test binary", name)
				}
			}()
			call()
		}()
	}
	if err := Check("/etc/passwd"); err != nil {
		t.Errorf("guard must remain disabled after the refusal: %v", err)
	}
}
