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
	if err := WriteCapabilityDropIn("powernode-redis-redis.service",
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
	if err := WriteCapabilityDropIn("powernode-postgres-postgres.service", nil); err != nil {
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
	err := WriteCapabilityDropIn("foo.service", []string{"CAP_MADE_UP"})
	if err == nil || !strings.Contains(err.Error(), "CAP_MADE_UP") {
		t.Errorf("expected error mentioning CAP_MADE_UP; got %v", err)
	}
}

func TestWriteCapabilityDropIn_RejectsPathTraversal(t *testing.T) {
	withTempSystemdRootCaps(t)
	for _, bad := range []string{"../escape", "foo/bar", "foo\x00null", "-leading-dash"} {
		if err := WriteCapabilityDropIn(bad, nil); err == nil {
			t.Errorf("expected error for unit name %q", bad)
		}
	}
}

func TestWriteCapabilityDropIn_IsIdempotent(t *testing.T) {
	root := withTempSystemdRootCaps(t)
	unit := "powernode-base.service"
	caps := []string{"CAP_NET_BIND_SERVICE", "CAP_CHOWN"}
	if err := WriteCapabilityDropIn(unit, caps); err != nil {
		t.Fatalf("first write: %v", err)
	}
	first, err := os.ReadFile(filepath.Join(root, unit+".d", "capabilities.conf"))
	if err != nil {
		t.Fatalf("read first: %v", err)
	}
	// Re-write with a permuted allowlist — sorted output must be identical.
	if err := WriteCapabilityDropIn(unit, []string{"cap_chown", "CAP_NET_BIND_SERVICE"}); err != nil {
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
