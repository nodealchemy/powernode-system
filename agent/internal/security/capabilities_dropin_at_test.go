package security

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// R5 (review round, IMP-caef5c00d63f phase 2): these guard tests existed for
// the retired WriteAmbientCapabilityDropInAt (ambient_capabilities_dropin_test.go,
// deleted when that function was replaced) and were not restored for its
// replacement, WriteCapabilityDropInAt, when it landed. Restored here,
// against the CURRENT function, plus the shared-validation guarantee that
// WriteCapabilityDropInAt and WriteCapabilityDropIn now refuse identically
// (validateDropInUnitName) rather than duplicating the checks.

func TestWriteCapabilityDropInAt_AllowListEmitsBothSetsAtExplicitRoot(t *testing.T) {
	root := t.TempDir()
	unit := "powernode-019e5b9a-bf81-traefik.service"
	if err := WriteCapabilityDropInAt(root, unit, []string{"CAP_NET_BIND_SERVICE", "cap_chown"}); err != nil {
		t.Fatalf("WriteCapabilityDropInAt: %v", err)
	}
	path := filepath.Join(root, "etc", "systemd", "system", unit+".d", "capabilities.conf")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read drop-in: %v", err)
	}
	s := string(body)
	if !strings.Contains(s, "CapabilityBoundingSet=\nCapabilityBoundingSet=CAP_CHOWN CAP_NET_BIND_SERVICE\n") {
		t.Errorf("bounding-set lines missing or unsorted: %s", s)
	}
	if !strings.Contains(s, "AmbientCapabilities=\nAmbientCapabilities=CAP_CHOWN CAP_NET_BIND_SERVICE\n") {
		t.Errorf("ambient lines missing or unsorted: %s", s)
	}
}

func TestWriteCapabilityDropInAt_EmptyAllowListStillWritesTheStrictestDropIn(t *testing.T) {
	// UNLIKE the retired ambient-only writer (which skipped the file entirely
	// for an empty allow list), this one ALWAYS writes — an absent drop-in
	// would leave the unit at systemd's full default bounding set, which is
	// exactly the gap IMP-caef5c00d63f phase 2 closes.
	root := t.TempDir()
	unit := "powernode-postgres-postgres.service"
	if err := WriteCapabilityDropInAt(root, unit, nil); err != nil {
		t.Fatalf("WriteCapabilityDropInAt: %v", err)
	}
	path := filepath.Join(root, "etc", "systemd", "system", unit+".d", "capabilities.conf")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("expected a drop-in for an empty allowlist (strictest posture, not a no-op); read err=%v", err)
	}
	s := string(body)
	if !strings.Contains(s, "CapabilityBoundingSet=\n") {
		t.Errorf("expected CapabilityBoundingSet=  (reset) line; got %s", s)
	}
	if !strings.Contains(s, "AmbientCapabilities=\n") {
		t.Errorf("expected AmbientCapabilities=  (reset) line; got %s", s)
	}
	if strings.Contains(s, "CAP_") {
		t.Errorf("expected zero CAP_* tokens in empty-allow drop-in; got %s", s)
	}
}

func TestWriteCapabilityDropInAt_RejectsUnknownCap(t *testing.T) {
	err := WriteCapabilityDropInAt(t.TempDir(), "foo.service", []string{"CAP_MADE_UP"})
	if err == nil || !strings.Contains(err.Error(), "CAP_MADE_UP") {
		t.Errorf("expected error mentioning CAP_MADE_UP; got %v", err)
	}
}

func TestWriteCapabilityDropInAt_RejectsPathTraversal(t *testing.T) {
	root := t.TempDir()
	for _, bad := range []string{"../escape", "foo/bar", "foo\x00null", "-leading-dash", ""} {
		if err := WriteCapabilityDropInAt(root, bad, []string{"CAP_CHOWN"}); err == nil {
			t.Errorf("expected error for unit name %q", bad)
		}
	}
}

func TestWriteCapabilityDropInAt_IsIdempotentAndSorted(t *testing.T) {
	root := t.TempDir()
	unit := "powernode-x.service"
	path := filepath.Join(root, "etc", "systemd", "system", unit+".d", "capabilities.conf")
	if err := WriteCapabilityDropInAt(root, unit, []string{"CAP_NET_BIND_SERVICE", "CAP_CHOWN"}); err != nil {
		t.Fatalf("first write: %v", err)
	}
	first, _ := os.ReadFile(path)
	if err := WriteCapabilityDropInAt(root, unit, []string{"cap_chown", "CAP_NET_BIND_SERVICE"}); err != nil {
		t.Fatalf("second write: %v", err)
	}
	second, _ := os.ReadFile(path)
	if string(first) != string(second) {
		t.Errorf("not idempotent under permutation:\nfirst=%s\nsecond=%s", first, second)
	}
	if !strings.Contains(string(first), "CapabilityBoundingSet=CAP_CHOWN CAP_NET_BIND_SERVICE\n") {
		t.Errorf("caps not sorted: %s", first)
	}
}

// SHARED VALIDATION (R5): WriteCapabilityDropIn and WriteCapabilityDropInAt
// must refuse the SAME invalid unit names, via the one shared
// validateDropInUnitName helper, not two independently-maintained copies of
// the same three checks (empty / path-traversal / leading-dash) that could
// silently drift apart.
func TestCapabilityDropInWriters_ShareUnitNameValidation(t *testing.T) {
	badNames := []string{"", "../escape", "foo/bar", "foo\x00null", "-leading-dash"}
	for _, bad := range badNames {
		atErr := WriteCapabilityDropInAt(t.TempDir(), bad, nil)
		liveErr := func() error {
			original := systemdDropInRoot
			systemdDropInRoot = t.TempDir()
			defer func() { systemdDropInRoot = original }()
			return WriteCapabilityDropIn(bad, nil)
		}()
		if (atErr == nil) != (liveErr == nil) {
			t.Errorf("unit %q: WriteCapabilityDropInAt err=%v, WriteCapabilityDropIn err=%v — the two writers disagree", bad, atErr, liveErr)
		}
	}
}
