package runtime

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// The priority-inversion repro (IMP 019fd966): a low-priority module added
// to the composition post-boot ships a path a HIGHER-priority module also
// ships. The union serves the higher layer's content, and the live root
// already reflects that. Syncing the added module must NOT copy its own
// (losing) version over the winner.
func TestSyncModuleFiles_HigherLayerWinsContestedPath(t *testing.T) {
	src := t.TempDir()    // the added, low-priority module
	higher := t.TempDir() // an already-attached, higher-priority module
	dst := t.TempDir()    // the live root, currently serving the winner

	writeTestFile(t, filepath.Join(src, "usr", "bin", "tool"), "low", 0o755)
	writeTestFile(t, filepath.Join(higher, "usr", "bin", "tool"), "high", 0o755)
	writeTestFile(t, filepath.Join(dst, "usr", "bin", "tool"), "high", 0o755)

	res, err := SyncModuleFiles(src, dst, SyncOptions{HigherLayers: []string{higher}})
	if err != nil {
		t.Fatalf("SyncModuleFiles: %v", err)
	}
	if got := readTestFile(t, filepath.Join(dst, "usr", "bin", "tool")); got != "high" {
		t.Errorf("live root serves %q, want %q — the added module shadowed a higher-priority layer", got, "high")
	}
	if res.Changed != 0 {
		t.Errorf("Changed = %d, want 0 (live view already matched the winner)", res.Changed)
	}
	if res.Contested != 1 {
		t.Errorf("Contested = %d, want 1", res.Contested)
	}
}

// When the live root does NOT yet have the contested path, the sync must
// materialize the WINNER's content, not the synced module's.
func TestSyncModuleFiles_MaterializesWinnerWhenDestMissing(t *testing.T) {
	src := t.TempDir()
	higher := t.TempDir()
	dst := t.TempDir()

	writeTestFile(t, filepath.Join(src, "etc", "app.conf"), "low", 0o644)
	writeTestFile(t, filepath.Join(higher, "etc", "app.conf"), "high", 0o644)

	res, err := SyncModuleFiles(src, dst, SyncOptions{HigherLayers: []string{higher}})
	if err != nil {
		t.Fatalf("SyncModuleFiles: %v", err)
	}
	if got := readTestFile(t, filepath.Join(dst, "etc", "app.conf")); got != "high" {
		t.Errorf("materialized %q, want the winner's %q", got, "high")
	}
	if res.Changed != 1 {
		t.Errorf("Changed = %d, want 1 (winner content was written)", res.Changed)
	}
	if res.Contested != 1 {
		t.Errorf("Contested = %d, want 1", res.Contested)
	}
}

// Of several higher layers, the FIRST (highest-priority, matching overlayfs
// lower order) that provides the path wins — same rule findInLayers already
// enforces for prune restores.
func TestSyncModuleFiles_HighestOfSeveralHigherLayersWins(t *testing.T) {
	src := t.TempDir()
	mid := t.TempDir()
	top := t.TempDir()
	dst := t.TempDir()

	writeTestFile(t, filepath.Join(src, "usr", "bin", "tool"), "low", 0o755)
	writeTestFile(t, filepath.Join(mid, "usr", "bin", "tool"), "mid", 0o755)
	writeTestFile(t, filepath.Join(top, "usr", "bin", "tool"), "top", 0o755)

	// Highest first, as the caller contract requires.
	_, err := SyncModuleFiles(src, dst, SyncOptions{HigherLayers: []string{top, mid}})
	if err != nil {
		t.Fatalf("SyncModuleFiles: %v", err)
	}
	if got := readTestFile(t, filepath.Join(dst, "usr", "bin", "tool")); got != "top" {
		t.Errorf("materialized %q, want %q (highest layer must win)", got, "top")
	}
}

// A contested SYMLINK must keep the winner's target, recreated verbatim.
func TestSyncModuleFiles_ContestedSymlinkKeepsWinnerTarget(t *testing.T) {
	src := t.TempDir()
	higher := t.TempDir()
	dst := t.TempDir()

	if err := os.Symlink("low-target", filepath.Join(src, "current")); err != nil {
		t.Fatalf("Symlink: %v", err)
	}
	if err := os.Symlink("high-target", filepath.Join(higher, "current")); err != nil {
		t.Fatalf("Symlink: %v", err)
	}

	_, err := SyncModuleFiles(src, dst, SyncOptions{HigherLayers: []string{higher}})
	if err != nil {
		t.Fatalf("SyncModuleFiles: %v", err)
	}
	got, rerr := os.Readlink(filepath.Join(dst, "current"))
	if rerr != nil {
		t.Fatalf("Readlink: %v", rerr)
	}
	if got != "high-target" {
		t.Errorf("symlink target = %q, want the winner's %q", got, "high-target")
	}
}

// Uncontested paths keep the plain copy behavior even when higher layers
// are supplied — winner resolution only fires on genuinely shared paths.
func TestSyncModuleFiles_UncontestedPathStillCopied(t *testing.T) {
	src := t.TempDir()
	higher := t.TempDir()
	dst := t.TempDir()

	writeTestFile(t, filepath.Join(src, "opt", "only-mine.txt"), "mine", 0o644)
	writeTestFile(t, filepath.Join(higher, "usr", "bin", "unrelated"), "x", 0o755)

	res, err := SyncModuleFiles(src, dst, SyncOptions{HigherLayers: []string{higher}})
	if err != nil {
		t.Fatalf("SyncModuleFiles: %v", err)
	}
	if got := readTestFile(t, filepath.Join(dst, "opt", "only-mine.txt")); got != "mine" {
		t.Errorf("uncontested file = %q, want %q", got, "mine")
	}
	if res.Contested != 0 {
		t.Errorf("Contested = %d, want 0", res.Contested)
	}
}

// The budget guard: a copy that would leave less than MinFreeBytes free
// aborts the walk with ErrScratchBudget and copies nothing further.
func TestSyncModuleFiles_BudgetGuardAborts(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	writeTestFile(t, filepath.Join(src, "a-first.bin"), "0123456789", 0o644)
	writeTestFile(t, filepath.Join(src, "b-second.bin"), "0123456789", 0o644)

	orig := freeBytesAt
	freeBytesAt = func(string) (uint64, error) { return 100, nil }
	t.Cleanup(func() { freeBytesAt = orig })

	res, err := SyncModuleFiles(src, dst, SyncOptions{MinFreeBytes: 1 << 20})
	if !errors.Is(err, ErrScratchBudget) {
		t.Fatalf("err = %v, want ErrScratchBudget", err)
	}
	if res.Changed != 0 {
		t.Errorf("Changed = %d, want 0 (nothing fit the budget)", res.Changed)
	}
	if _, statErr := os.Stat(filepath.Join(dst, "b-second.bin")); !os.IsNotExist(statErr) {
		t.Errorf("walk continued past the budget abort (b-second.bin exists)")
	}
}

// Identical files never charge the budget — a no-drift repeat tick must
// succeed even with zero headroom.
func TestSyncModuleFiles_IdenticalFilesBypassBudget(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	writeTestFile(t, filepath.Join(src, "same.txt"), "same", 0o644)
	writeTestFile(t, filepath.Join(dst, "same.txt"), "same", 0o644)

	orig := freeBytesAt
	freeBytesAt = func(string) (uint64, error) { return 0, nil }
	t.Cleanup(func() { freeBytesAt = orig })

	res, err := SyncModuleFiles(src, dst, SyncOptions{MinFreeBytes: 1 << 20})
	if err != nil {
		t.Fatalf("SyncModuleFiles: %v", err)
	}
	if res.Changed != 0 {
		t.Errorf("Changed = %d, want 0", res.Changed)
	}
}
