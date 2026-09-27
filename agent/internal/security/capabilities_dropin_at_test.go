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
	if _, err := WriteCapabilityDropInAt(root, unit, []string{"CAP_NET_BIND_SERVICE", "cap_chown"}); err != nil {
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
	if _, err := WriteCapabilityDropInAt(root, unit, nil); err != nil {
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
	_, err := WriteCapabilityDropInAt(t.TempDir(), "foo.service", []string{"CAP_MADE_UP"})
	if err == nil || !strings.Contains(err.Error(), "CAP_MADE_UP") {
		t.Errorf("expected error mentioning CAP_MADE_UP; got %v", err)
	}
}

func TestWriteCapabilityDropInAt_RejectsPathTraversal(t *testing.T) {
	root := t.TempDir()
	for _, bad := range []string{
		"../escape", "foo/bar", "foo\x00null", "-leading-dash", "",
		// Mutant killers (review, IMP-caef5c00d63f phase 3): every prior case
		// above pairs its bad character with a "/" (path-traversal shape), so
		// a mutant that only rejects "/.." or "../" — instead of ".." on its
		// own — would still pass them all. Neither case below has a slash.
		"escape..d", // bare ".." with no path separator anywhere
		"foo\\bar",  // bare backslash with no path separator anywhere
	} {
		if _, err := WriteCapabilityDropInAt(root, bad, []string{"CAP_CHOWN"}); err == nil {
			t.Errorf("expected error for unit name %q", bad)
		}
	}
}

func TestWriteCapabilityDropInAt_IsIdempotentAndSorted(t *testing.T) {
	root := t.TempDir()
	unit := "powernode-x.service"
	path := filepath.Join(root, "etc", "systemd", "system", unit+".d", "capabilities.conf")
	if _, err := WriteCapabilityDropInAt(root, unit, []string{"CAP_NET_BIND_SERVICE", "CAP_CHOWN"}); err != nil {
		t.Fatalf("first write: %v", err)
	}
	first, _ := os.ReadFile(path)
	if _, err := WriteCapabilityDropInAt(root, unit, []string{"cap_chown", "CAP_NET_BIND_SERVICE"}); err != nil {
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

// SHARED VALIDATION (R5, extended IMP-caef5c00d63f phase 3/4 to
// WriteUserNamespaceDropIn and WriteSeccompDropIn once they stopped carrying
// their own copies of the same three checks — userns_dropin.go, mac.go). All
// FOUR drop-in writers must refuse the SAME invalid unit names, via the one
// shared validateDropInUnitName helper, not independently-maintained copies
// of the same checks (empty / path-traversal / leading-dash) that could
// silently drift apart.
func TestCapabilityDropInWriters_ShareUnitNameValidation(t *testing.T) {
	badNames := []string{"", "../escape", "foo/bar", "foo\x00null", "-leading-dash", "escape..d", "foo\\bar"}
	for _, bad := range badNames {
		_, atErr := WriteCapabilityDropInAt(t.TempDir(), bad, nil)
		liveErr := func() error {
			original := systemdDropInRoot
			systemdDropInRoot = t.TempDir()
			defer func() { systemdDropInRoot = original }()
			_, err := WriteCapabilityDropIn(bad, nil)
			return err
		}()
		usernsErr := func() error {
			original := systemdDropInRoot
			systemdDropInRoot = t.TempDir()
			defer func() { systemdDropInRoot = original }()
			_, err := WriteUserNamespaceDropIn(bad, true)
			return err
		}()
		seccompErr := func() error {
			original := systemdDropInRoot
			systemdDropInRoot = t.TempDir()
			defer func() { systemdDropInRoot = original }()
			_, err := WriteSeccompDropIn(bad, "")
			return err
		}()
		if (atErr == nil) != (liveErr == nil) {
			t.Errorf("unit %q: WriteCapabilityDropInAt err=%v, WriteCapabilityDropIn err=%v — the two writers disagree", bad, atErr, liveErr)
		}
		if (atErr == nil) != (usernsErr == nil) {
			t.Errorf("unit %q: WriteCapabilityDropInAt err=%v, WriteUserNamespaceDropIn err=%v — the writers disagree", bad, atErr, usernsErr)
		}
		if (atErr == nil) != (seccompErr == nil) {
			t.Errorf("unit %q: WriteCapabilityDropInAt err=%v, WriteSeccompDropIn err=%v — the writers disagree", bad, atErr, seccompErr)
		}
	}
}
