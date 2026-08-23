package security

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withTempSystemdRoot redirects systemdDropInRoot for the duration
// of the test and restores it after.
func withTempSystemdRoot(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	original := systemdDropInRoot
	systemdDropInRoot = dir
	t.Cleanup(func() { systemdDropInRoot = original })
	return dir
}

func TestWriteSeccompDropInBasic(t *testing.T) {
	root := withTempSystemdRoot(t)

	// Uses a systemd predefined syscall set name, which is the only spelling
	// that yields a directive systemd actually understands after '@'. A profile
	// FILE base name ("deny.json") is also accepted by the writer and produces
	// "SystemCallFilter=@deny.json", which systemd does NOT understand — that
	// is a pre-existing ambiguity in what security.seccomp_profile means (a
	// path, per ApplySeccompProfile's os.Stat, or a set name, per this
	// directive), tracked separately. This test asserts the drop-in SHAPE, and
	// deliberately does not bless the broken spelling as expected output.
	if err := WriteSeccompDropIn("nginx.service", "/etc/seccomp/system-service"); err != nil {
		t.Fatalf("WriteSeccompDropIn: %v", err)
	}

	dropIn := filepath.Join(root, "nginx.service.d", "seccomp.conf")
	got, err := os.ReadFile(dropIn)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	want := "[Service]\nSystemCallFilter=@system-service\nSystemCallErrorNumber=EPERM\n"
	if string(got) != want {
		t.Errorf("body mismatch:\ngot  %q\nwant %q", got, want)
	}

	st, _ := os.Stat(dropIn)
	if st.Mode().Perm() != 0o644 {
		t.Errorf("mode: got %v want 0644", st.Mode().Perm())
	}
}

func TestWriteSeccompDropInRejectsTraversal(t *testing.T) {
	withTempSystemdRoot(t)
	cases := []string{
		"../etc/passwd",
		"foo/../bar.service",
		"foo/bar.service",
		"./local.service",
		"\x00null.service",
		"-evil.service",
	}
	for _, name := range cases {
		t.Run(name, func(t *testing.T) {
			if err := WriteSeccompDropIn(name, "/path/p.json"); err == nil {
				t.Errorf("expected rejection of unit name %q", name)
			}
		})
	}
}

func TestWriteSeccompDropInRejectsUnusableProfilePaths(t *testing.T) {
	withTempSystemdRoot(t)
	if err := WriteSeccompDropIn("", "/x/p.json"); err == nil {
		t.Errorf("empty unit should error")
	}
	if err := WriteSeccompDropIn("nginx.service", ""); err == nil {
		t.Errorf("empty profilePath should error")
	}
	if err := WriteSeccompDropIn("nginx.service", "/etc/seccomp/"); err == nil {
		t.Errorf("profilePath with no base name should error")
	}
}

func TestWriteSeccompDropInOverwrites(t *testing.T) {
	withTempSystemdRoot(t)

	if err := WriteSeccompDropIn("sshd.service", "/etc/seccomp/old-profile.json"); err != nil {
		t.Fatalf("first write: %v", err)
	}
	if err := WriteSeccompDropIn("sshd.service", "/etc/seccomp/new-profile.json"); err != nil {
		t.Fatalf("second write: %v", err)
	}

	dropIn := filepath.Join(systemdDropInRoot, "sshd.service.d", "seccomp.conf")
	got, _ := os.ReadFile(dropIn)
	if !strings.Contains(string(got), "@new-profile.json") {
		t.Errorf("overwrite failed: %q", got)
	}
	if strings.Contains(string(got), "@old-profile.json") {
		t.Errorf("old content remained: %q", got)
	}
}

func TestWriteSeccompDropInCreatesParentDir(t *testing.T) {
	root := withTempSystemdRoot(t)
	expectedDir := filepath.Join(root, "fresh.service.d")

	// Confirm the parent doesn't exist.
	if _, err := os.Stat(expectedDir); !os.IsNotExist(err) {
		t.Fatalf("parent dir already exists: %v", err)
	}

	if err := WriteSeccompDropIn("fresh.service", "/path/p.json"); err != nil {
		t.Fatalf("WriteSeccompDropIn: %v", err)
	}
	if _, err := os.Stat(expectedDir); err != nil {
		t.Errorf("parent dir should have been created: %v", err)
	}
}
