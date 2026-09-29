package writeguard

import (
	"os"
	"path/filepath"
	"testing"
)

// The guard is only proven by both arms: it must FIRE on an out-of-sandbox
// path and PASS on an in-sandbox one, and it must do so unprivileged (the
// verdict is on the path, so no /etc write is ever attempted here).
func TestCheck(t *testing.T) {
	sandbox := t.TempDir()
	Enable(sandbox)
	t.Cleanup(func() { Disable(); Reset() })

	outside := t.TempDir() // a second, unrelated root standing in for /etc
	link := filepath.Join(sandbox, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name string
		path string
		bad  bool
	}{
		{"sandbox file, not yet created", filepath.Join(sandbox, "etc", "passwd"), false},
		{"sandbox root itself", sandbox, false},
		{"real etc passwd", "/etc/passwd", true},
		{"real sudoers.d", "/etc/sudoers.d", true},
		{"sibling of the sandbox", outside, true},
		{"dotdot escape", filepath.Join(sandbox, "..", "elsewhere"), true},
		{"relative path", "etc/passwd", true},
		{"symlink out of the sandbox", filepath.Join(link, "passwd"), true},
	}
	for _, c := range cases {
		Reset()
		err := Check(c.path)
		if got := err != nil; got != c.bad {
			t.Errorf("%s: Check(%q) error=%v, want violation=%v", c.name, c.path, err, c.bad)
		}
		if got := len(Reset()) > 0; got != c.bad {
			t.Errorf("%s: recorded=%v, want %v", c.name, got, c.bad)
		}
	}
}

func TestCheckHostFiresOnlyWhenEnabled(t *testing.T) {
	Disable()
	if err := CheckHost("sethostname"); err != nil {
		t.Fatalf("disabled guard must be a no-op, got %v", err)
	}
	Enable(t.TempDir())
	t.Cleanup(func() { Disable(); Reset() })
	if err := CheckHost("sethostname"); err == nil {
		t.Fatal("enabled guard must refuse a host-global effect")
	}
	if len(Reset()) != 1 {
		t.Fatal("violation not recorded")
	}
}

func TestDisabledIsNoOp(t *testing.T) {
	Disable()
	if err := Check("/etc/passwd"); err != nil {
		t.Fatalf("disabled guard must not refuse, got %v", err)
	}
	if v := Reset(); len(v) != 0 {
		t.Fatalf("disabled guard recorded %v", v)
	}
}

func TestRunForcesNonZeroOnAViolationEvenWhenTestsPass(t *testing.T) {
	Disable()
	t.Cleanup(func() { Disable(); Reset() })
	code := Run(func() int {
		_ = Check("/etc/passwd")
		return 0
	})
	if code == 0 {
		t.Fatal("Run returned 0 despite a recorded violation")
	}
	if code := Run(func() int { return 0 }); code != 0 {
		t.Fatalf("Run returned %d with no violation", code)
	}
}
