package etcsudoers

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

func staticClock() func() time.Time {
	t := time.Date(2026, 5, 22, 12, 0, 0, 0, time.UTC)
	return func() time.Time { return t }
}

func TestApplyAtWritesGrantFile(t *testing.T) {
	dir := t.TempDir()
	grants := []Grant{
		{
			ModuleName: "powernode-postgres",
			Grant: manifest.ManifestSudoer{
				ID:        "reload",
				User:      "postgres",
				RunasUser: "root",
				Commands:  []string{"/usr/bin/systemctl reload postgresql.service"},
			},
		},
	}
	if err := ApplyAt(grants, dir, staticClock()); err != nil {
		t.Fatalf("ApplyAt: %v", err)
	}

	expected := filepath.Join(dir, "powernode-powernode-postgres-reload")
	body, err := os.ReadFile(expected)
	if err != nil {
		t.Fatalf("read grant file: %v", err)
	}
	if !strings.Contains(string(body), "postgres ALL=(root) NOPASSWD: /usr/bin/systemctl reload postgresql.service") {
		t.Errorf("grant body unexpected:\n%s", string(body))
	}

	st, err := os.Stat(expected)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if st.Mode().Perm() != 0440 {
		t.Errorf("mode = %o want 0440", st.Mode().Perm())
	}
}

func TestApplyAtSweepsOrphanedPowernodeFiles(t *testing.T) {
	dir := t.TempDir()

	// Pre-populate: one stale powernode-* file + one operator file.
	stale := filepath.Join(dir, "powernode-old-thing")
	operator := filepath.Join(dir, "90-admins")
	if err := os.WriteFile(stale, []byte("# stale\n"), 0440); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(operator, []byte("alice ALL=(ALL) NOPASSWD: ALL\n"), 0440); err != nil {
		t.Fatal(err)
	}

	// Apply with one grant that does NOT match the stale file.
	grants := []Grant{
		{
			ModuleName: "powernode-redis",
			Grant: manifest.ManifestSudoer{
				ID: "ops", User: "redis", Commands: []string{"/bin/systemctl reload redis"},
			},
		},
	}
	if err := ApplyAt(grants, dir, staticClock()); err != nil {
		t.Fatalf("ApplyAt: %v", err)
	}

	// Stale powernode-* file should be gone.
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Errorf("expected stale file removed, got err=%v", err)
	}
	// Operator-authored file with no powernode- prefix must be preserved.
	if _, err := os.Stat(operator); err != nil {
		t.Errorf("operator file unexpectedly removed: %v", err)
	}
	// New grant file must exist.
	if _, err := os.Stat(filepath.Join(dir, "powernode-powernode-redis-ops")); err != nil {
		t.Errorf("new grant file missing: %v", err)
	}
}

func TestApplyAtEmptyGrantsSweepsAllManaged(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"powernode-a-x", "powernode-b-y", "90-admins"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("# x\n"), 0440); err != nil {
			t.Fatal(err)
		}
	}

	if err := ApplyAt(nil, dir, staticClock()); err != nil {
		t.Fatalf("ApplyAt: %v", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	names := []string{}
	for _, e := range entries {
		names = append(names, e.Name())
	}
	if len(names) != 1 || names[0] != "90-admins" {
		t.Errorf("after sweep got %v, want only [90-admins]", names)
	}
}

func TestApplyAtMkdirsIfNeeded(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "sudoers.d")
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("precondition: dir should not exist yet")
	}
	if err := ApplyAt(nil, dir, staticClock()); err != nil {
		t.Fatalf("ApplyAt: %v", err)
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		t.Errorf("dir not created: stat=%v err=%v", st, err)
	}
}
