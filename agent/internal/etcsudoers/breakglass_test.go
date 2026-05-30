package etcsudoers

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestApplyOperatorBreakGlass_WritesFileWhenEnabled(t *testing.T) {
	dir := t.TempDir()
	if err := ApplyOperatorBreakGlassAt(true, dir); err != nil {
		t.Fatalf("ApplyOperatorBreakGlassAt: %v", err)
	}

	path := filepath.Join(dir, OperatorBreakGlassFilename)
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if !strings.Contains(string(body), "pnadmin ALL=(ALL) NOPASSWD: ALL") {
		t.Errorf("body missing canonical grant line:\n%s", string(body))
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o440 {
		t.Errorf("file perms = %v, want 0440", info.Mode().Perm())
	}
}

func TestApplyOperatorBreakGlass_RemovesFileWhenDisabled(t *testing.T) {
	dir := t.TempDir()
	// First enable to stage a file.
	if err := ApplyOperatorBreakGlassAt(true, dir); err != nil {
		t.Fatalf("seed: %v", err)
	}
	path := filepath.Join(dir, OperatorBreakGlassFilename)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("file should exist after enable: %v", err)
	}

	// Now disable; file must go.
	if err := ApplyOperatorBreakGlassAt(false, dir); err != nil {
		t.Fatalf("ApplyOperatorBreakGlassAt(disabled): %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("file should be absent after disable, got err=%v", err)
	}
}

func TestApplyOperatorBreakGlass_DisableIsNoOpWhenAbsent(t *testing.T) {
	dir := t.TempDir()
	if err := ApplyOperatorBreakGlassAt(false, dir); err != nil {
		t.Errorf("disable on empty dir should no-op, got: %v", err)
	}
}

func TestApplyOperatorBreakGlass_EnableIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	if err := ApplyOperatorBreakGlassAt(true, dir); err != nil {
		t.Fatalf("first enable: %v", err)
	}
	path := filepath.Join(dir, OperatorBreakGlassFilename)
	info1, _ := os.Stat(path)
	mtime1 := info1.ModTime()

	// Second enable on matching content must NOT rewrite — the early-out
	// check on body equality saves the visudo fork. Verify mtime
	// doesn't advance (AtomicWrite would update mtime on a real write).
	if err := ApplyOperatorBreakGlassAt(true, dir); err != nil {
		t.Fatalf("second enable: %v", err)
	}
	info2, _ := os.Stat(path)
	if !info2.ModTime().Equal(mtime1) {
		t.Errorf("second enable rewrote the file (mtime changed %v -> %v)",
			mtime1, info2.ModTime())
	}
}

func TestApplyOperatorBreakGlass_DoesNotTouchOtherFiles(t *testing.T) {
	dir := t.TempDir()
	// Stage a manifest-driven powernode-* file that the break-glass
	// machinery should leave alone.
	manifestDriven := filepath.Join(dir, "powernode-hub-backend-deploy")
	if err := os.WriteFile(manifestDriven, []byte("# some other grant\n"), 0o440); err != nil {
		t.Fatal(err)
	}

	if err := ApplyOperatorBreakGlassAt(true, dir); err != nil {
		t.Fatalf("enable: %v", err)
	}
	if _, err := os.Stat(manifestDriven); err != nil {
		t.Errorf("manifest-driven file removed by break-glass enable: %v", err)
	}

	if err := ApplyOperatorBreakGlassAt(false, dir); err != nil {
		t.Fatalf("disable: %v", err)
	}
	if _, err := os.Stat(manifestDriven); err != nil {
		t.Errorf("manifest-driven file removed by break-glass disable: %v", err)
	}
}

func TestApplyOperatorBreakGlass_SurvivesSweep(t *testing.T) {
	// Regression: the break-glass file uses the "powernode-" prefix so
	// it's recognizable as Powernode-managed. Apply()'s sweep removes
	// any powernode-* file not in its keep-set; without the explicit
	// exclusion in sweep(), the break-glass file gets deleted on every
	// reconcile cycle (the file is enabled by ApplyOperatorBreakGlass,
	// not by Apply, so it never appears in the keep-set).
	dir := t.TempDir()
	if err := ApplyOperatorBreakGlassAt(true, dir); err != nil {
		t.Fatalf("enable: %v", err)
	}
	path := filepath.Join(dir, OperatorBreakGlassFilename)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("file should exist after enable: %v", err)
	}

	// Apply with NO grants — simulates the reconcile cycle when the
	// platform has no manifest-declared sudoers entries (typical for
	// most modules). Sweep() will iterate; should leave the
	// break-glass file alone.
	if err := ApplyAt(nil, dir, time.Now); err != nil {
		t.Fatalf("ApplyAt(empty): %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("break-glass file removed by Apply()'s sweep: %v", err)
	}
}

func TestOperatorBreakGlassEnabledFromEnv(t *testing.T) {
	cases := map[string]bool{
		"":      false,
		"0":     false,
		"false": false,
		"no":    false,
		"junk":  false,
		"1":     true,
		"true":  true,
		"TRUE":  true,
		"True":  true,
		"yes":   true,
		"YES":   true,
	}
	for value, want := range cases {
		t.Run(value, func(t *testing.T) {
			t.Setenv("POWERNODE_OPERATOR_BREAK_GLASS", value)
			if got := OperatorBreakGlassEnabledFromEnv(); got != want {
				t.Errorf("value=%q: got %v, want %v", value, got, want)
			}
		})
	}
}
