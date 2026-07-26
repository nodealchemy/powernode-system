package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func stagedSet(t *testing.T, dir string, digest string, attempts int) string {
	t.Helper()
	// The blob must exist for validation to pass — the pre-pivot consumer has no
	// network to fetch it with.
	cache := filepath.Join(dir, "cache")
	if err := os.MkdirAll(cache, 0o755); err != nil {
		t.Fatal(err)
	}
	if digest != "" {
		if err := os.WriteFile(filepath.Join(cache, "blob.erofs"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	p := &PendingCompose{
		Set: BootLKG{
			ConfirmedAt: time.Now().UTC(),
			Modules: []LKGModule{{
				ID: "m1", Name: "mod-one", EffectivePriority: 100,
				HasDataFile: true, Digest: digest, Manifest: json.RawMessage(`{"id":"m1"}`),
			}},
		},
		StagedAt: time.Now().UTC(),
		Attempts: attempts,
	}
	path := filepath.Join(dir, "pending.json")
	if err := WritePendingCompose(path, p); err != nil {
		t.Fatal(err)
	}
	return path
}

func cacheFor(dir string) func(string) string {
	return func(string) string { return filepath.Join(dir, "cache", "blob.erofs") }
}

// The attempt MUST be recorded before the caller composes: a set that hangs the
// boot has to burn its try, or the node retries it forever.
func TestTakePendingCompose_BurnsAnAttemptBeforeReturning(t *testing.T) {
	dir := t.TempDir()
	path := stagedSet(t, dir, "sha256:aa", 0)

	got := TakePendingCompose(path, cacheFor(dir), nil)
	if got == nil {
		t.Fatal("expected a usable staged set")
	}
	if got.Attempts != 1 {
		t.Errorf("returned Attempts = %d, want 1", got.Attempts)
	}
	// Crucially, it must be on DISK already — not just in the returned struct.
	onDisk, err := LoadPendingCompose(path)
	if err != nil {
		t.Fatal(err)
	}
	if onDisk.Attempts != 1 {
		t.Errorf("attempt not persisted before compose: on-disk Attempts = %d, want 1", onDisk.Attempts)
	}
}

func TestTakePendingCompose_StopsAfterMaxTries(t *testing.T) {
	dir := t.TempDir()
	path := stagedSet(t, dir, "sha256:aa", PendingMaxTries)

	if got := TakePendingCompose(path, cacheFor(dir), nil); got != nil {
		t.Error("exhausted staged set was offered again — the node would retry a bad set forever")
	}
}

// A staged set whose blob is missing must be refused: the pre-pivot consumer
// cannot fetch it, so composing would produce a root that cannot mount.
func TestTakePendingCompose_RefusesWhenBlobIsAbsent(t *testing.T) {
	dir := t.TempDir()
	path := stagedSet(t, dir, "sha256:aa", 0)
	if err := os.Remove(filepath.Join(dir, "cache", "blob.erofs")); err != nil {
		t.Fatal(err)
	}
	if got := TakePendingCompose(path, cacheFor(dir), nil); got != nil {
		t.Error("offered a staged set whose blob is not cached")
	}
}

// Absent is the normal case and must be silent, not an error path.
func TestTakePendingCompose_AbsentIsNotAnError(t *testing.T) {
	dir := t.TempDir()
	called := 0
	got := TakePendingCompose(filepath.Join(dir, "nope.json"), cacheFor(dir), func(string, error) { called++ })
	if got != nil {
		t.Error("expected nil for an absent staged set")
	}
	if called != 0 {
		t.Errorf("absent staged set reported %d errors; it is the normal case", called)
	}
}

// Tamper detection comes free from reusing the LKG checksum contract.
func TestTakePendingCompose_RefusesATamperedSet(t *testing.T) {
	dir := t.TempDir()
	path := stagedSet(t, dir, "sha256:aa", 0)

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var p PendingCompose
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatal(err)
	}
	p.Set.Modules[0].Digest = "sha256:bb" // checksum now stale
	edited, _ := json.Marshal(p)
	if err := os.WriteFile(path, edited, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := TakePendingCompose(path, cacheFor(dir), nil); got != nil {
		t.Error("offered a staged set whose checksum no longer matches its modules")
	}
}

func TestSameComposition(t *testing.T) {
	a := []LKGModule{{ID: "1", Digest: "d1"}, {ID: "2", Digest: "d2"}}
	if !sameComposition(a, []LKGModule{{ID: "2", Digest: "d2"}, {ID: "1", Digest: "d1"}}) {
		t.Error("order should not matter")
	}
	if sameComposition(a, []LKGModule{{ID: "1", Digest: "d1"}, {ID: "2", Digest: "CHANGED"}}) {
		t.Error("a changed digest must count as different")
	}
	if sameComposition(a, []LKGModule{{ID: "1", Digest: "d1"}}) {
		t.Error("a dropped module must count as different")
	}
	// Priority churn alone must NOT restage — it would burn attempts without
	// changing what actually mounts.
	if !sameComposition(a, []LKGModule{{ID: "1", Digest: "d1", EffectivePriority: 9}, {ID: "2", Digest: "d2"}}) {
		t.Error("priority-only change should not count as a different composition")
	}
}
