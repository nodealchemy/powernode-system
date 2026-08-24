package security

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// IMP-01a02f70-9bfb — the pivot/compose path must apply the same seccomp +
// PrivateUsers confinement the cloud_init attach path applies, written into
// the union at an explicit sysroot. These test the explicit-root writers.
// SAFETY: t.TempDir() only.

func TestWriteSeccompDropInAt_WritesUnderSysroot(t *testing.T) {
	root := t.TempDir()
	if err := WriteSeccompDropInAt(root, "app.service", "system-service"); err != nil {
		t.Fatalf("WriteSeccompDropInAt: %v", err)
	}
	p := filepath.Join(root, "etc", "systemd", "system", "app.service.d", "seccomp.conf")
	got, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("expected drop-in under sysroot: %v", err)
	}
	if want := "SystemCallFilter=@system-service"; !strings.Contains(string(got), want) {
		t.Errorf("body %q missing %q", got, want)
	}
	// The injection barrier still holds on the At-variant: a newline-bearing
	// profile must be refused and write NO file.
	if err := WriteSeccompDropInAt(root, "app2.service", "deny\nUser=root"); err == nil {
		t.Error("At-variant accepted an injection payload")
	}
	if _, err := os.Stat(filepath.Join(root, "etc", "systemd", "system", "app2.service.d", "seccomp.conf")); !os.IsNotExist(err) {
		t.Error("refused payload still left a drop-in")
	}
}

func TestWriteUserNamespaceDropInAt_WritesUnderSysroot(t *testing.T) {
	root := t.TempDir()
	if err := WriteUserNamespaceDropInAt(root, "app.service", true); err != nil {
		t.Fatalf("WriteUserNamespaceDropInAt: %v", err)
	}
	p := filepath.Join(root, "etc", "systemd", "system", "app.service.d", "userns.conf")
	got, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("expected drop-in under sysroot: %v", err)
	}
	if !strings.Contains(string(got), "PrivateUsers=yes") {
		t.Errorf("body %q missing PrivateUsers=yes", got)
	}
}
