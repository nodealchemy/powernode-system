package identity

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
)

func counter(t *testing.T, f *consoleFixture) int {
	t.Helper()
	return refusalCount(consoleRefusalsPath)
}

// Round 2 / item 1: cleanup keys on HOW the file was staged, not on the
// document's purpose. A pasted document keeps its server purpose ("enroll").
func TestPastedDocumentStagedFileRemovedAfterRefusalAndCounted(t *testing.T) {
	f := fixtureWithState(t, consoleDoc("")+"\n", bootCfgPinned)
	id, err := f.s.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if id.Purpose != "enroll" {
		t.Fatalf("test premise: pasted document keeps its server purpose, got %q", id.Purpose)
	}
	if _, err := os.Stat(f.stage); err != nil {
		t.Fatal("not staged")
	}
	id.EnrolRefused()
	if _, err := os.Stat(f.stage); err == nil {
		t.Fatal("dead pasted document must be deleted after a 4xx")
	}
	if got := counter(t, f); got != 1 {
		t.Fatalf("refusal counter = %d, want 1", got)
	}
	if _, err := os.Stat(consoleMarkerPath); err == nil {
		t.Fatal("marker must go with the file")
	}
}

func TestPastedDocumentStagedFileRemovedAfterSuccess(t *testing.T) {
	f := fixtureWithState(t, consoleDoc("")+"\n", bootCfgPinned)
	os.WriteFile(consoleRefusalsPath, []byte("2"), 0o600)
	id, err := f.s.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	id.EnrolSucceeded()
	if _, err := os.Stat(f.stage); err == nil {
		t.Fatal("plaintext document must be deleted after a successful enrolment")
	}
	if counter(t, f) != 0 {
		t.Fatal("success resets the counter")
	}
}

// After an agent restart the identity comes back through LocalIdentityStrategy
// (no console provenance in memory): the on-disk marker still drives cleanup.
func TestStagedFileCleanedAfterRestartViaLocalStrategy(t *testing.T) {
	f := fixtureWithState(t, consoleDoc("")+"\n", bootCfgPinned)
	if _, err := f.s.Discover(context.Background()); err != nil {
		t.Fatal(err)
	}
	again, err := (&LocalIdentityStrategy{Path: f.stage}).Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if again.CloudProvider == "console-prompt" {
		t.Fatal("test premise: provenance is lost after restart")
	}
	again.EnrolRefused()
	if _, err := os.Stat(f.stage); err == nil {
		t.Fatal("staged document must be deleted on 4xx even when re-read after a restart")
	}
	if counter(t, f) != 1 {
		t.Fatal("restart-path refusal must be counted")
	}
}

func TestCleanupOnlyForTheStagedKey(t *testing.T) {
	f := fixtureWithState(t, consoleDoc("")+"\n", bootCfgPinned)
	if _, err := f.s.Discover(context.Background()); err != nil {
		t.Fatal(err)
	}
	other := &Identity{BootstrapToken: "not-a-real-other-key", Purpose: ConsolePurpose}
	other.EnrolRefused()
	other.EnrolSucceeded()
	if _, err := os.Stat(f.stage); err != nil {
		t.Fatal("an unrelated identity's outcome must not delete the staged key")
	}
	if counter(t, f) != 0 {
		t.Fatal("unrelated refusal must not count")
	}
}

// Item 5: cleanup uses the configured stage path, not the package default.
func TestCleanupUsesConfiguredStagePath(t *testing.T) {
	f := fixtureWithState(t, consoleKey+"\n", bootCfgPinned)
	if f.s.StagePath == DefaultStagePath {
		t.Fatal("premise: fixture uses a non-default stage path")
	}
	id, err := f.s.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	id.EnrolSucceeded()
	if _, err := os.Stat(f.stage); err == nil {
		t.Fatal("configured stage path must be cleaned")
	}
}

// Item 3 (agent half): the BOOT ID= is the CSR subject when present.
func TestBareKeyUsesBootIDAsSubject(t *testing.T) {
	const bootID = "0190aaaa-bbbb-cccc-dddd-eeeeffff0042"
	f := fixtureWithState(t, consoleKey+"\n", bootCfgPinned+"ID="+bootID+"\n")
	id, err := f.s.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if id.InstanceUUID != bootID {
		t.Fatalf("subject = %q, want the BOOT ID", id.InstanceUUID)
	}
	raw, _ := os.ReadFile(f.stage)
	if !strings.Contains(string(raw), bootID) || strings.Contains(string(raw), PlaceholderInstanceID) {
		t.Fatal("staged document must carry the BOOT ID")
	}
	// malformed ID falls back to the placeholder rather than failing the paste
	f = fixtureWithState(t, consoleKey+"\n", bootCfgPinned+"ID=not-a-uuid\n")
	id, err = f.s.Discover(context.Background())
	if err != nil || id.InstanceUUID != PlaceholderInstanceID {
		t.Fatalf("%v %+v", err, id)
	}
}

func TestTransientEnrolFailureLeavesStagedKeyAlone(t *testing.T) {
	// a 5xx is neither EnrolRefused nor EnrolSucceeded: nothing to call, nothing deleted.
	f := fixtureWithState(t, consoleDoc("")+"\n", bootCfgPinned)
	if _, err := f.s.Discover(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(f.stage); err != nil || counter(t, f) != 0 {
		t.Fatal("staged key must survive until a definitive outcome")
	}
	_ = errors.New
}
