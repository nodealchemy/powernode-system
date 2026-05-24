package enroll

import (
	"os"
	"path/filepath"
	"testing"
)

// TestResolveDefaultPKIDir_FHS asserts the resolver picks the FHS path
// when /persist/var/lib/powernode isn't present. This is the cloud-VM
// case (ProxmoxProvider file-fallback spawn, Vultr/AWS/GCP cutovers).
//
// We can't truly hide /persist from the running test process — it may
// exist on the developer's host — so we exercise the path predicate
// (dirExists) directly to keep the test hermetic, then assert the
// resolver returns one of the two canonical constants either way.
func TestResolveDefaultPKIDir_PicksOneOfTheTwoConstants(t *testing.T) {
	got := ResolveDefaultPKIDir()
	if got != PKIDirInitramfs && got != PKIDirFHS {
		t.Fatalf("ResolveDefaultPKIDir returned %q; want one of %q or %q",
			got, PKIDirInitramfs, PKIDirFHS)
	}
}

func TestResolveDefaultPKIDir_AgreesWithFilesystem(t *testing.T) {
	expected := PKIDirFHS
	if dirExists("/persist/var/lib/powernode") {
		expected = PKIDirInitramfs
	}
	if got := ResolveDefaultPKIDir(); got != expected {
		t.Fatalf("ResolveDefaultPKIDir returned %q; want %q based on /persist/var/lib/powernode presence",
			got, expected)
	}
}

// TestDirExists exercises the predicate directly so the resolver's
// decision is testable in both directions without monkey-patching the
// running OS's /persist tree.
func TestDirExists(t *testing.T) {
	tmpDir := t.TempDir()
	present := filepath.Join(tmpDir, "present")
	if err := os.MkdirAll(present, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if !dirExists(present) {
		t.Fatalf("dirExists(%q) returned false; expected true", present)
	}

	absent := filepath.Join(tmpDir, "absent")
	if dirExists(absent) {
		t.Fatalf("dirExists(%q) returned true; expected false (path does not exist)", absent)
	}

	// File (not directory) — must return false; the resolver should not
	// be fooled into treating a stray /persist/var/lib/powernode FILE
	// as a valid persist layer.
	file := filepath.Join(tmpDir, "file")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if dirExists(file) {
		t.Fatalf("dirExists(%q) returned true; expected false (regular file, not dir)", file)
	}
}

// TestResolveDefaultPKIPaths is a smoke test for the convenience wrapper —
// asserts it returns a populated PKIPaths struct rooted at whichever dir
// the resolver picked.
func TestResolveDefaultPKIPaths(t *testing.T) {
	paths := ResolveDefaultPKIPaths()
	dir := ResolveDefaultPKIDir()

	if paths.Dir != dir {
		t.Fatalf("Dir = %q; want %q", paths.Dir, dir)
	}
	if paths.Key != filepath.Join(dir, "node.key") {
		t.Fatalf("Key = %q; want %q/node.key", paths.Key, dir)
	}
	if paths.Cert != filepath.Join(dir, "node.crt") {
		t.Fatalf("Cert = %q; want %q/node.crt", paths.Cert, dir)
	}
}

// TestPKIDirLegacyAlias guards against a future cleanup that drops the
// legacy alias before all call sites are migrated.
func TestPKIDirLegacyAlias(t *testing.T) {
	if PKIDir != PKIDirInitramfs {
		t.Fatalf("PKIDir legacy alias drifted from PKIDirInitramfs: PKIDir=%q PKIDirInitramfs=%q",
			PKIDir, PKIDirInitramfs)
	}
}
