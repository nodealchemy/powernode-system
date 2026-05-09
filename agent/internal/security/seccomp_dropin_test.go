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

	if err := WriteSeccompDropIn("nginx.service", "default-deny", "/etc/seccomp/default-deny.json"); err != nil {
		t.Fatalf("WriteSeccompDropIn: %v", err)
	}

	dropIn := filepath.Join(root, "nginx.service.d", "seccomp.conf")
	got, err := os.ReadFile(dropIn)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	want := "[Service]\nSystemCallFilter=@default-deny\nSystemCallErrorNumber=EPERM\n"
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
			if err := WriteSeccompDropIn(name, "p", "/path"); err == nil {
				t.Errorf("expected rejection of unit name %q", name)
			}
		})
	}
}

func TestWriteSeccompDropInRequiresAllArgs(t *testing.T) {
	withTempSystemdRoot(t)
	if err := WriteSeccompDropIn("", "p", "/x"); err == nil {
		t.Errorf("empty unit should error")
	}
	if err := WriteSeccompDropIn("nginx.service", "", "/x"); err == nil {
		t.Errorf("empty profile should error")
	}
	if err := WriteSeccompDropIn("nginx.service", "p", ""); err == nil {
		t.Errorf("empty profilePath should error")
	}
}

func TestWriteSeccompDropInOverwrites(t *testing.T) {
	withTempSystemdRoot(t)

	if err := WriteSeccompDropIn("sshd.service", "old-profile", "/etc/seccomp/old.json"); err != nil {
		t.Fatalf("first write: %v", err)
	}
	if err := WriteSeccompDropIn("sshd.service", "new-profile", "/etc/seccomp/new.json"); err != nil {
		t.Fatalf("second write: %v", err)
	}

	dropIn := filepath.Join(systemdDropInRoot, "sshd.service.d", "seccomp.conf")
	got, _ := os.ReadFile(dropIn)
	if !strings.Contains(string(got), "@new-profile") {
		t.Errorf("overwrite failed: %q", got)
	}
	if strings.Contains(string(got), "@old-profile") {
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

	if err := WriteSeccompDropIn("fresh.service", "p", "/path"); err != nil {
		t.Fatalf("WriteSeccompDropIn: %v", err)
	}
	if _, err := os.Stat(expectedDir); err != nil {
		t.Errorf("parent dir should have been created: %v", err)
	}
}
