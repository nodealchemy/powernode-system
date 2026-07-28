package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
)

func pendingState(t *testing.T) {
	t.Helper()
	restore := bootslots.SetStatePathForTest(filepath.Join(t.TempDir(), "boot-slot.json"))
	t.Cleanup(restore)
	if err := bootslots.Update(func(s *bootslots.State) error {
		s.Active = "a"
		s.Pending = "b"
		s.PendingSHA = "1111111111111111111111111111111111111111"
		s.LastTargetSHA = "1111111111111111111111111111111111111111"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func runAbandon(t *testing.T, args ...string) string {
	t.Helper()
	c := abandonBootImageCmd()
	var out bytes.Buffer
	c.SetOut(&out)
	c.SetErr(&out)
	c.SetArgs(args)
	if err := c.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}
	return out.String()
}

// Dry-run is the default: an operator reaching for this is already in a bad
// state and must not make it worse by omitting a flag.
func TestAbandonBootImage_DryRunChangesNothing(t *testing.T) {
	pendingState(t)
	out := runAbandon(t)

	if !strings.Contains(out, "DRY RUN") {
		t.Errorf("expected a dry-run notice, got:\n%s", out)
	}
	if st := bootslots.Load(); st.Pending != "b" || st.PendingSHA == "" {
		t.Errorf("dry run mutated state: %+v", st)
	}
	// It must warn about the case that actually hurts.
	if !strings.Contains(out, "CURRENTLY RUNNING") {
		t.Errorf("dry run did not warn about abandoning the running slot:\n%s", out)
	}
}

func TestAbandonBootImage_YesClearsPendingButNotActive(t *testing.T) {
	pendingState(t)
	runAbandon(t, "--yes")

	st := bootslots.Load()
	if st.Pending != "" || st.PendingSHA != "" {
		t.Errorf("pending not cleared: %+v", st)
	}
	if st.Active != "a" {
		t.Errorf("ACTIVE slot was modified (%q) — the rollback target must never be touched", st.Active)
	}
}

// No upgrade in flight must be a clean no-op, not an error: this is the state an
// operator lands in after a successful abandon or a normal confirm.
func TestAbandonBootImage_NoPendingIsANoOp(t *testing.T) {
	restore := bootslots.SetStatePathForTest(filepath.Join(t.TempDir(), "boot-slot.json"))
	defer restore()

	out := runAbandon(t, "--yes")
	if !strings.Contains(out, "nothing to abandon") {
		t.Errorf("expected a no-op message, got:\n%s", out)
	}
}

// Abandoning must also drop the recorded target sha. It deliberately outlives
// Pending everywhere else — that is what lets a later healthy boot bless a slot
// whose first attempt fell back — but here the operator has said the attempt is
// over. Leaving it behind lets the reconciliation path bless the abandoned slot
// on a subsequent boot, silently undoing this command.
func TestAbandonBootImage_AlsoClearsTheRecordedTarget(t *testing.T) {
	pendingState(t)
	runAbandon(t, "--yes")

	if st := bootslots.Load(); st.LastTargetSHA != "" {
		t.Fatalf("abandon left the target sha behind (%q) — a later boot onto slot %q would "+
			"bless the very upgrade the operator just abandoned", st.LastTargetSHA, "b")
	}
}
