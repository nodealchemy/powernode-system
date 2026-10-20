package identity

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// Round 3 / item 1: no staged key without a marker.
func TestMarkerFailureLeavesNoStagedFile(t *testing.T) {
	f := fixtureWithState(t, consoleDoc("")+"\n", bootCfgPinned)
	// the marker's parent is a regular file => writeMarker cannot succeed
	blocker := filepath.Join(t.TempDir(), "blocker")
	os.WriteFile(blocker, []byte("x"), 0o600)
	consoleMarkerPath = filepath.Join(blocker, "console-staged")
	_, err := f.s.Discover(context.Background())
	if err == nil {
		t.Fatal("staging must fail when the marker cannot be written")
	}
	if _, serr := os.Stat(f.stage); serr == nil {
		t.Fatal("a key must never be left staged without its marker")
	}
}

func TestStageFailureAfterMarkerRemovesMarker(t *testing.T) {
	f := fixtureWithState(t, consoleDoc("")+"\n", bootCfgPinned)
	// the target path is a non-empty directory => the final rename fails
	os.MkdirAll(filepath.Join(f.stage, "sub"), 0o700)
	if _, err := f.s.Discover(context.Background()); err == nil {
		t.Fatal("staging must fail")
	}
	if _, err := os.Stat(consoleMarkerPath); err == nil {
		t.Fatal("marker must not outlive a failed staging")
	}
}

func TestMarkerWrittenFirstAndAtomically(t *testing.T) {
	f := fixtureWithState(t, consoleDoc("")+"\n", bootCfgPinned)
	if _, err := f.s.Discover(context.Background()); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(consoleMarkerPath)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("marker: %v %v", err, st)
	}
	leftovers, _ := filepath.Glob(consoleMarkerPath + "*")
	if len(leftovers) != 1 {
		t.Fatalf("temp files left behind: %v", leftovers)
	}
}
