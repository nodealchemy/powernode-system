package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The regression this exists for: prepare-root used to MkdirAll(sysroot/sbin),
// which on a usr-merged distro replaces the /sbin -> usr/sbin symlink with a
// real directory containing only init. Every other binary in /usr/sbin then
// disappears from /sbin, silently breaking anything that resolves by /sbin path
// (qemu-ga's /sbin/shutdown, the kernel's /sbin/modprobe).
func TestEnsureSbin_CreatesSymlinkPreservingUsrMerge(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "usr", "sbin"), 0o755); err != nil {
		t.Fatal(err)
	}
	// A binary only reachable through the merge.
	if err := os.WriteFile(filepath.Join(root, "usr", "sbin", "modprobe"), []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}

	if err := ensureSbin(root); err != nil {
		t.Fatalf("ensureSbin: %v", err)
	}

	fi, err := os.Lstat(filepath.Join(root, "sbin"))
	if err != nil {
		t.Fatalf("no /sbin created: %v", err)
	}
	if fi.Mode()&os.ModeSymlink == 0 {
		t.Fatal("/sbin was created as a DIRECTORY — usr-merge destroyed, /usr/sbin hidden")
	}
	// The whole point: /usr/sbin's contents must be reachable via /sbin.
	if _, err := os.Stat(filepath.Join(root, "sbin", "modprobe")); err != nil {
		t.Errorf("/sbin/modprobe does not resolve through the merge: %v", err)
	}
}

// switch-root chase-validates /sbin/init, so it must still resolve.
func TestEnsureSbin_InitResolvesThroughTheSymlink(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "usr", "sbin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "usr", "lib", "systemd"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "usr", "lib", "systemd", "systemd"), []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := ensureSbin(root); err != nil {
		t.Fatal(err)
	}
	// Mirror what ensureCanonicalInit does next.
	if err := os.Symlink("/usr/lib/systemd/systemd", filepath.Join(root, "sbin", "init")); err != nil {
		t.Fatalf("symlink init through /sbin: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(root, "usr", "sbin", "init")); err != nil {
		t.Errorf("init did not land in usr/sbin through the merge: %v", err)
	}
}

// A pre-existing real /sbin (non-usr-merged layout) must be left alone.
func TestEnsureSbin_LeavesAnExistingRealDirectoryAlone(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "sbin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "sbin", "preexisting"), []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "usr", "sbin"), 0o755); err != nil {
		t.Fatal(err)
	}

	if err := ensureSbin(root); err != nil {
		t.Fatal(err)
	}

	fi, err := os.Lstat(filepath.Join(root, "sbin"))
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		t.Error("replaced a real /sbin with a symlink — would hide its existing contents")
	}
	if _, err := os.Stat(filepath.Join(root, "sbin", "preexisting")); err != nil {
		t.Errorf("existing /sbin content lost: %v", err)
	}
}

// No /usr/sbin at all: fall back to a real directory so switch-root still works.
func TestEnsureSbin_FallsBackToDirectoryWithoutUsrSbin(t *testing.T) {
	root := t.TempDir()
	if err := ensureSbin(root); err != nil {
		t.Fatalf("ensureSbin: %v", err)
	}
	fi, err := os.Lstat(filepath.Join(root, "sbin"))
	if err != nil {
		t.Fatalf("no /sbin created: %v", err)
	}
	if !fi.IsDir() {
		t.Error("expected a real directory when there is no usr/sbin to merge with")
	}
}
