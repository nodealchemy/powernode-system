package security

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The pivot-compose ambient drop-in writer takes an EXPLICIT root (the union at
// sysroot), not the systemdDropInRoot package var — so these tests point it at a
// t.TempDir() directly and assert the file lands under
// <root>/etc/systemd/system/<unit>.d/ambient-capabilities.conf.

func TestWriteAmbientCapabilityDropInAt_GrantsAmbientOnly(t *testing.T) {
	root := t.TempDir()
	unit := "powernode-019e5b9a-bf81-traefik.service"
	if err := WriteAmbientCapabilityDropInAt(root, unit, []string{"cap_net_bind_service"}); err != nil {
		t.Fatalf("WriteAmbientCapabilityDropInAt: %v", err)
	}
	path := filepath.Join(root, "etc", "systemd", "system", unit+".d", "ambient-capabilities.conf")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read drop-in: %v", err)
	}
	s := string(body)
	if !strings.Contains(s, "AmbientCapabilities=\nAmbientCapabilities=CAP_NET_BIND_SERVICE\n") {
		t.Errorf("ambient grant missing/normalized wrong: %s", s)
	}
	// The whole point: it must NOT restrict the bounding set (that's the risky
	// half deferred pending a per-module cap audit). Check for the directive
	// form (with '='); the explanatory comment mentions the word without one.
	if strings.Contains(s, "CapabilityBoundingSet=") {
		t.Errorf("ambient-only drop-in must NOT emit a CapabilityBoundingSet= directive; got %s", s)
	}
}

func TestWriteAmbientCapabilityDropInAt_EmptyAllowIsNoOp(t *testing.T) {
	root := t.TempDir()
	unit := "powernode-postgres-postgres.service"
	if err := WriteAmbientCapabilityDropInAt(root, unit, nil); err != nil {
		t.Fatalf("WriteAmbientCapabilityDropInAt: %v", err)
	}
	// No caps declared -> no file written (unit keeps systemd defaults).
	path := filepath.Join(root, "etc", "systemd", "system", unit+".d", "ambient-capabilities.conf")
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("expected no drop-in for empty allowlist; stat err=%v", err)
	}
}

func TestWriteAmbientCapabilityDropInAt_RejectsUnknownCap(t *testing.T) {
	err := WriteAmbientCapabilityDropInAt(t.TempDir(), "foo.service", []string{"CAP_MADE_UP"})
	if err == nil || !strings.Contains(err.Error(), "CAP_MADE_UP") {
		t.Errorf("expected error mentioning CAP_MADE_UP; got %v", err)
	}
}

func TestWriteAmbientCapabilityDropInAt_RejectsPathTraversal(t *testing.T) {
	root := t.TempDir()
	for _, bad := range []string{"../escape", "foo/bar", "foo\x00null", "-leading-dash", ""} {
		if err := WriteAmbientCapabilityDropInAt(root, bad, []string{"CAP_CHOWN"}); err == nil {
			t.Errorf("expected error for unit name %q", bad)
		}
	}
}

func TestWriteAmbientCapabilityDropInAt_IsIdempotentAndSorted(t *testing.T) {
	root := t.TempDir()
	unit := "powernode-x.service"
	path := filepath.Join(root, "etc", "systemd", "system", unit+".d", "ambient-capabilities.conf")
	if err := WriteAmbientCapabilityDropInAt(root, unit, []string{"CAP_NET_BIND_SERVICE", "CAP_CHOWN"}); err != nil {
		t.Fatalf("first write: %v", err)
	}
	first, _ := os.ReadFile(path)
	if err := WriteAmbientCapabilityDropInAt(root, unit, []string{"cap_chown", "CAP_NET_BIND_SERVICE"}); err != nil {
		t.Fatalf("second write: %v", err)
	}
	second, _ := os.ReadFile(path)
	if string(first) != string(second) {
		t.Errorf("not idempotent under permutation:\nfirst=%s\nsecond=%s", first, second)
	}
	if !strings.Contains(string(first), "AmbientCapabilities=CAP_CHOWN CAP_NET_BIND_SERVICE\n") {
		t.Errorf("caps not sorted: %s", first)
	}
}
