package runtime

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSyncModuleFilesToRootNewFile(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	writeTestFile(t, filepath.Join(src, "hello.txt"), "hello", 0o644)

	changed, err := SyncModuleFilesToRoot(src, dst)
	if err != nil {
		t.Fatalf("SyncModuleFilesToRoot: %v", err)
	}
	if changed != 1 {
		t.Errorf("changed = %d, want 1", changed)
	}
	if got := readTestFile(t, filepath.Join(dst, "hello.txt")); got != "hello" {
		t.Errorf("dst content = %q, want %q", got, "hello")
	}
}

func TestSyncModuleFilesToRootOverwritesModifiedFile(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	// Same size ("version=1" / "version=2"), different content — exercises
	// the hash-compare branch of filesIdentical, not just the cheap
	// size-mismatch short-circuit.
	writeTestFile(t, filepath.Join(src, "app.conf"), "version=2", 0o644)
	writeTestFile(t, filepath.Join(dst, "app.conf"), "version=1", 0o644)

	changed, err := SyncModuleFilesToRoot(src, dst)
	if err != nil {
		t.Fatalf("SyncModuleFilesToRoot: %v", err)
	}
	if changed != 1 {
		t.Errorf("changed = %d, want 1", changed)
	}
	if got := readTestFile(t, filepath.Join(dst, "app.conf")); got != "version=2" {
		t.Errorf("dst content = %q, want %q (module content should win)", got, "version=2")
	}
}

func TestSyncModuleFilesToRootPreservesExecutableBit(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	writeTestFile(t, filepath.Join(src, "caddy"), "#!/bin/sh\necho hi\n", 0o755)

	if _, err := SyncModuleFilesToRoot(src, dst); err != nil {
		t.Fatalf("SyncModuleFilesToRoot: %v", err)
	}
	info, err := os.Stat(filepath.Join(dst, "caddy"))
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Errorf("mode = %v, want 0755 (executable bit must survive the copy — a replaced binary must stay runnable)", info.Mode().Perm())
	}
}

func TestSyncModuleFilesToRootCreatesNestedDirs(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	nested := filepath.Join(src, "usr", "share", "app", "data")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	writeTestFile(t, filepath.Join(nested, "seed.json"), `{"ok":true}`, 0o644)

	if _, err := SyncModuleFilesToRoot(src, dst); err != nil {
		t.Fatalf("SyncModuleFilesToRoot: %v", err)
	}
	if got := readTestFile(t, filepath.Join(dst, "usr", "share", "app", "data", "seed.json")); got != `{"ok":true}` {
		t.Errorf("dst content = %q", got)
	}
	if fi, err := os.Stat(filepath.Join(dst, "usr", "share", "app")); err != nil || !fi.IsDir() {
		t.Errorf("expected intermediate dir usr/share/app to exist, err=%v", err)
	}
}

func TestSyncModuleFilesToRootRecreatesSymlink(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	writeTestFile(t, filepath.Join(src, "real.txt"), "payload", 0o644)
	if err := os.Symlink("real.txt", filepath.Join(src, "link.txt")); err != nil {
		t.Fatalf("Symlink: %v", err)
	}

	changed, err := SyncModuleFilesToRoot(src, dst)
	if err != nil {
		t.Fatalf("SyncModuleFilesToRoot: %v", err)
	}
	if changed != 2 { // real.txt (new file) + link.txt (new symlink)
		t.Errorf("changed = %d, want 2", changed)
	}

	fi, err := os.Lstat(filepath.Join(dst, "link.txt"))
	if err != nil {
		t.Fatalf("Lstat: %v", err)
	}
	if fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("link.txt was dereferenced into a regular file — must stay a symlink, never followed")
	}
	target, err := os.Readlink(filepath.Join(dst, "link.txt"))
	if err != nil {
		t.Fatalf("Readlink: %v", err)
	}
	if target != "real.txt" {
		t.Errorf("symlink target = %q, want %q", target, "real.txt")
	}
}

func TestSyncModuleFilesToRootIdempotentSecondCall(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	nested := filepath.Join(src, "etc", "app")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	writeTestFile(t, filepath.Join(nested, "config.yaml"), "key: value", 0o644)
	if err := os.Symlink("config.yaml", filepath.Join(nested, "current.yaml")); err != nil {
		t.Fatalf("Symlink: %v", err)
	}

	first, err := SyncModuleFilesToRoot(src, dst)
	if err != nil {
		t.Fatalf("first SyncModuleFilesToRoot: %v", err)
	}
	if first == 0 {
		t.Fatalf("first call reported changed = 0, want > 0")
	}

	second, err := SyncModuleFilesToRoot(src, dst)
	if err != nil {
		t.Fatalf("second SyncModuleFilesToRoot: %v", err)
	}
	if second != 0 {
		t.Errorf("second (idempotent) call changed = %d, want 0 — repeat calls must be quiet no-ops", second)
	}
}

func TestSyncModuleFilesToRootLeavesUnrelatedDestFileUntouched(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	writeTestFile(t, filepath.Join(src, "module-owned.txt"), "from module", 0o644)
	writeTestFile(t, filepath.Join(dst, "pre-existing.txt"), "not from this module", 0o644)

	if _, err := SyncModuleFilesToRoot(src, dst); err != nil {
		t.Fatalf("SyncModuleFilesToRoot: %v", err)
	}

	// v1 deletions are out of scope — a dest file the module doesn't ship
	// must never be removed or altered just because it wasn't in src.
	if got := readTestFile(t, filepath.Join(dst, "pre-existing.txt")); got != "not from this module" {
		t.Errorf("pre-existing unrelated dest file was modified: got %q", got)
	}
}

func writeTestFile(t *testing.T, path, body string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	// os.WriteFile only applies mode to a newly-created file; force it
	// explicitly so a test that overwrites an existing dest path still
	// gets exactly the mode it asked for.
	if err := os.Chmod(path, mode); err != nil {
		t.Fatalf("Chmod: %v", err)
	}
}

func readTestFile(t *testing.T, path string) string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile %s: %v", path, err)
	}
	return string(body)
}
