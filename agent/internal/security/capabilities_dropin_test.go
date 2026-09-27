package security

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withTempSystemdRootCaps mirrors the seccomp_dropin_test helper —
// redirects systemdDropInRoot to a per-test tmp dir so the drop-in
// writer can be exercised in unit tests without touching /etc/systemd.
func withTempSystemdRootCaps(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	original := systemdDropInRoot
	systemdDropInRoot = dir
	t.Cleanup(func() { systemdDropInRoot = original })
	return dir
}

func TestWriteCapabilityDropIn_AllowsListEmitsBothSets(t *testing.T) {
	root := withTempSystemdRootCaps(t)
	if _, err := WriteCapabilityDropIn("powernode-redis-redis.service",
		[]string{"CAP_NET_BIND_SERVICE", "cap_chown"}); err != nil {
		t.Fatalf("WriteCapabilityDropIn: %v", err)
	}
	path := filepath.Join(root, "powernode-redis-redis.service.d", "capabilities.conf")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read drop-in: %v", err)
	}
	s := string(body)
	// Bounding set + ambient set both reset and re-asserted.
	if !strings.Contains(s, "CapabilityBoundingSet=\nCapabilityBoundingSet=CAP_CHOWN CAP_NET_BIND_SERVICE\n") {
		t.Errorf("bounding-set lines missing or unsorted: %s", s)
	}
	if !strings.Contains(s, "AmbientCapabilities=\nAmbientCapabilities=CAP_CHOWN CAP_NET_BIND_SERVICE\n") {
		t.Errorf("ambient lines missing or unsorted: %s", s)
	}
}

func TestWriteCapabilityDropIn_EmptyAllowListDropsAll(t *testing.T) {
	root := withTempSystemdRootCaps(t)
	if _, err := WriteCapabilityDropIn("powernode-postgres-postgres.service", nil); err != nil {
		t.Fatalf("WriteCapabilityDropIn: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(root, "powernode-postgres-postgres.service.d", "capabilities.conf"))
	if err != nil {
		t.Fatalf("read drop-in: %v", err)
	}
	s := string(body)
	// Strict posture: explicitly empty bounding + ambient sets.
	if !strings.Contains(s, "CapabilityBoundingSet=\n") {
		t.Errorf("expected CapabilityBoundingSet=  (reset) line; got %s", s)
	}
	if !strings.Contains(s, "AmbientCapabilities=\n") {
		t.Errorf("expected AmbientCapabilities=  (reset) line; got %s", s)
	}
	// No CAP_ tokens should appear when allowlist is empty.
	if strings.Contains(s, "CAP_") {
		t.Errorf("expected zero CAP_* tokens in empty-allow drop-in; got %s", s)
	}
}

func TestWriteCapabilityDropIn_RejectsUnknownCap(t *testing.T) {
	withTempSystemdRootCaps(t)
	_, err := WriteCapabilityDropIn("foo.service", []string{"CAP_MADE_UP"})
	if err == nil || !strings.Contains(err.Error(), "CAP_MADE_UP") {
		t.Errorf("expected error mentioning CAP_MADE_UP; got %v", err)
	}
}

func TestWriteCapabilityDropIn_RejectsPathTraversal(t *testing.T) {
	withTempSystemdRootCaps(t)
	for _, bad := range []string{"../escape", "foo/bar", "foo\x00null", "-leading-dash"} {
		if _, err := WriteCapabilityDropIn(bad, nil); err == nil {
			t.Errorf("expected error for unit name %q", bad)
		}
	}
}

func TestWriteCapabilityDropIn_IsIdempotent(t *testing.T) {
	root := withTempSystemdRootCaps(t)
	unit := "powernode-base.service"
	caps := []string{"CAP_NET_BIND_SERVICE", "CAP_CHOWN"}
	if _, err := WriteCapabilityDropIn(unit, caps); err != nil {
		t.Fatalf("first write: %v", err)
	}
	first, err := os.ReadFile(filepath.Join(root, unit+".d", "capabilities.conf"))
	if err != nil {
		t.Fatalf("read first: %v", err)
	}
	// Re-write with a permuted allowlist — sorted output must be identical.
	if _, err := WriteCapabilityDropIn(unit, []string{"cap_chown", "CAP_NET_BIND_SERVICE"}); err != nil {
		t.Fatalf("second write: %v", err)
	}
	second, err := os.ReadFile(filepath.Join(root, unit+".d", "capabilities.conf"))
	if err != nil {
		t.Fatalf("read second: %v", err)
	}
	if string(first) != string(second) {
		t.Errorf("drop-in not idempotent under name permutation:\nfirst=%s\nsecond=%s", first, second)
	}
}

// TestWriteCapabilityDropIn_ReportsChanged is W1 (IMP-caef5c00d63f round W,
// HIGH) at its foundation: the FIRST write of a unit's capabilities.conf
// (nothing on disk yet), a write that genuinely changes the allow list, and
// a write of byte-identical content must report changed=true, true, false
// respectively — this is the ONLY signal a caller deciding whether a
// RUNNING unit needs a daemon-reload/restart has, since a capability-only
// edit moves no unit body at all.
func TestWriteCapabilityDropIn_ReportsChanged(t *testing.T) {
	withTempSystemdRootCaps(t)
	unit := "powernode-x-app.service"

	changed, err := WriteCapabilityDropIn(unit, []string{"CAP_CHOWN"})
	if err != nil {
		t.Fatalf("first write: %v", err)
	}
	if !changed {
		t.Error("W1 REGRESSION: the FIRST write of a drop-in (nothing on disk yet) must report changed=true")
	}

	changed, err = WriteCapabilityDropIn(unit, []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	if err != nil {
		t.Fatalf("second write (genuinely different allow list): %v", err)
	}
	if !changed {
		t.Error("W1 REGRESSION: a write with a genuinely DIFFERENT allow list must report changed=true")
	}

	changed, err = WriteCapabilityDropIn(unit, []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	if err != nil {
		t.Fatalf("third write (byte-identical): %v", err)
	}
	if changed {
		t.Error("W1 REGRESSION: re-writing byte-identical content must report changed=false")
	}
}

// TestWriteCapabilityDropIn_RemovesLegacyAmbientFile is W3
// (IMP-caef5c00d63f round W): an older compose could have left a
// stand-alone ambient-capabilities.conf in the SAME <unit>.d directory —
// writing the current capabilities.conf must clean it up, and its removal
// must itself count toward the returned changed signal (W1).
func TestWriteCapabilityDropIn_RemovesLegacyAmbientFile(t *testing.T) {
	root := withTempSystemdRootCaps(t)
	unit := "powernode-x-app.service"
	legacyPath := filepath.Join(root, unit+".d", "ambient-capabilities.conf")
	if err := os.MkdirAll(filepath.Dir(legacyPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyPath, []byte("[Service]\nAmbientCapabilities=CAP_NET_BIND_SERVICE\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	changed, err := WriteCapabilityDropIn(unit, []string{"CAP_CHOWN"})
	if err != nil {
		t.Fatalf("WriteCapabilityDropIn: %v", err)
	}
	if !changed {
		t.Error("W3/W1 REGRESSION: removing the legacy ambient file must itself report changed=true")
	}
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Errorf("W3 REGRESSION: expected the legacy ambient-capabilities.conf to be removed, stat err=%v", err)
	}
}

// TestRemoveCapabilityDropIn_RemovesLegacyAmbientFile is W3's sibling for
// the opt-out path (a unit becoming privileged, R7's own hygiene case).
func TestRemoveCapabilityDropIn_RemovesLegacyAmbientFile(t *testing.T) {
	root := withTempSystemdRootCaps(t)
	unit := "powernode-x-app.service"
	dropInDir := filepath.Join(root, unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		t.Fatal(err)
	}
	capPath := filepath.Join(dropInDir, "capabilities.conf")
	legacyPath := filepath.Join(dropInDir, "ambient-capabilities.conf")
	if err := os.WriteFile(capPath, []byte("stub"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyPath, []byte("stub"), 0o644); err != nil {
		t.Fatal(err)
	}

	changed, err := RemoveCapabilityDropIn(unit)
	if err != nil {
		t.Fatalf("RemoveCapabilityDropIn: %v", err)
	}
	if !changed {
		t.Error("W3/W1 REGRESSION: expected changed=true when either file was actually removed")
	}
	if _, err := os.Stat(capPath); !os.IsNotExist(err) {
		t.Errorf("expected capabilities.conf removed, stat err=%v", err)
	}
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Errorf("W3 REGRESSION: expected the legacy ambient-capabilities.conf also removed, stat err=%v", err)
	}
}
