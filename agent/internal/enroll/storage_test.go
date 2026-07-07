package enroll

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestResolveDefaultPKIDir_PicksOneOfTheTwoConstants asserts the resolver
// returns one of the two canonical constants. We can't fake /persist being
// its own mount from an unprivileged test, so we exercise the mount
// predicate (isDistinctMount) directly below to cover both directions.
func TestResolveDefaultPKIDir_PicksOneOfTheTwoConstants(t *testing.T) {
	got := ResolveDefaultPKIDir()
	if got != PKIDirInitramfs && got != PKIDirFHS {
		t.Fatalf("ResolveDefaultPKIDir returned %q; want one of %q or %q",
			got, PKIDirInitramfs, PKIDirFHS)
	}
}

func TestResolveDefaultPKIDir_AgreesWithFilesystem(t *testing.T) {
	expected := PKIDirFHS
	if isDistinctMount("/persist") {
		expected = PKIDirInitramfs
	}
	if got := ResolveDefaultPKIDir(); got != expected {
		t.Fatalf("ResolveDefaultPKIDir returned %q; want %q based on /persist being a distinct mount",
			got, expected)
	}
}

// TestIsDistinctMount exercises the mount predicate directly. The false
// cases (a dir on the same fs as its parent, and a missing path) are
// deterministic; the true case is cross-checked against /proc/mounts so
// it only asserts when /proc is genuinely mounted (minimal sandboxes may
// not mount it).
func TestIsDistinctMount(t *testing.T) {
	// A subdir of the test tmp tree shares its parent's filesystem.
	tmpDir := t.TempDir()
	child := filepath.Join(tmpDir, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if isDistinctMount(child) {
		t.Errorf("isDistinctMount(%q) = true; want false (same fs as parent)", child)
	}

	// A path that doesn't exist is not a mount.
	if isDistinctMount(filepath.Join(tmpDir, "absent")) {
		t.Error("isDistinctMount(absent) = true; want false (path does not exist)")
	}

	// Positive case: /proc is its own mount on a real Linux host.
	if mountpointListed("/proc") {
		if !isDistinctMount("/proc") {
			t.Error("isDistinctMount(/proc) = false; want true (/proc is a mount)")
		}
	} else {
		t.Log("/proc not listed in /proc/mounts; skipping positive assertion")
	}
}

func mountpointListed(mp string) bool {
	data, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		if f := strings.Fields(line); len(f) >= 2 && f[1] == mp {
			return true
		}
	}
	return false
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

// TestSave_PersistsPlatformURL_RoundTrip covers the post-pivot cert-adoption
// fix's data path: Save writes the enrolled platform URL into meta.json and
// ReadPlatformURL reads it back, so the service can reconstruct its client
// without the discovery resolver.
func TestSave_PersistsPlatformURL_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	paths := PathsUnder(dir)
	kp, err := GenerateKeypair()
	if err != nil {
		t.Fatalf("GenerateKeypair: %v", err)
	}
	id := &EnrolledIdentity{
		Keypair:     kp,
		CertPEM:     []byte("CERT"),
		CAChainPEM:  []byte("CA-CHAIN"),
		CABundlePEM: []byte("CA-BUNDLE"),
		InstanceID:  "inst-1",
		PlatformURL: "https://platform.example.test",
	}
	if err := Save(id, paths); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if got := ReadPlatformURL(paths); got != id.PlatformURL {
		t.Errorf("ReadPlatformURL = %q, want %q", got, id.PlatformURL)
	}
}

// TestReadPlatformURL_MissingOrLegacy asserts ReadPlatformURL degrades to ""
// (never panics) when the meta file is absent or predates the platform_url
// field — in which case bootstrap correctly falls through to discovery.
func TestReadPlatformURL_MissingOrLegacy(t *testing.T) {
	dir := t.TempDir()
	paths := PathsUnder(dir)
	if got := ReadPlatformURL(paths); got != "" {
		t.Errorf("ReadPlatformURL(no meta) = %q, want empty", got)
	}
	if err := os.WriteFile(paths.Meta, []byte(`{"instance_id":"x"}`), 0o644); err != nil {
		t.Fatalf("write legacy meta: %v", err)
	}
	if got := ReadPlatformURL(paths); got != "" {
		t.Errorf("ReadPlatformURL(legacy meta) = %q, want empty", got)
	}
}
