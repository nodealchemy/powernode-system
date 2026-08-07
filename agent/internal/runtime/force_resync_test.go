package runtime

import (
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// After a bad artifact whiteout-deleted files off a live root (2026-08-07:
// /usr/local/go and /usr/local/bin/gitleaks), there was no supported way to put
// them back. Recovery was a hand bind-mount of the cached erofs over a root
// shell — not a platform action, not auditable, and unavailable to an operator
// who is not already root on the box.
//
// system_refresh_instance_modules already existed, but it dispatches a
// sync_modules task whose handler is plain RunOnce — and RunOnce SKIPS a module
// whose digest is already attached with an unchanged ServicesHash. So the one
// operator action that sounds like a resync cannot repair a root whose files
// were deleted underneath an unchanged digest: there is no drift to detect.
//
// The lever is the same one the budget-abort retry uses: LastAttachedManifestHashes
// is what the reattach gate compares, so clearing an entry re-queues that module
// for materialization on the very next pass.
func writeStateWithStamps(t *testing.T, dir string, stamps map[string]string) string {
	t.Helper()
	path := filepath.Join(dir, "state.json")
	st := &mount.State{LastAttachedManifestHashes: stamps}
	for id := range stamps {
		st.AttachedModules = append(st.AttachedModules, mount.Module{ID: id, Digest: "sha256:" + id})
	}
	if err := mount.SaveState(path, st); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestClearAttachedManifestHashes_SingleModule(t *testing.T) {
	dir := t.TempDir()
	path := writeStateWithStamps(t, dir, map[string]string{
		"runtime-go": "hash-a",
		"redis":      "hash-b",
	})
	r := &Reconciler{cfg: ReconcilerConfig{StatePath: path, OnError: func(string, error) {}}}

	if err := r.ClearAttachedManifestHashes("runtime-go"); err != nil {
		t.Fatalf("ClearAttachedManifestHashes: %v", err)
	}

	st, err := mount.LoadState(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, still := st.LastAttachedManifestHashes["runtime-go"]; still {
		t.Fatal("runtime-go stamp survived; the reattach gate will still consider it synced and skip it")
	}
	if st.LastAttachedManifestHashes["redis"] != "hash-b" {
		t.Fatal("clearing one module must not disturb another module's stamp")
	}
	// The module stays ATTACHED — the erofs layer really is mounted; only the
	// file materialization is being redone. Dropping it from AttachedModules
	// would make the next pass treat this as a fresh attach and re-mount.
	if len(st.AttachedModules) != 2 {
		t.Fatalf("AttachedModules = %d, want 2 (a resync must not detach anything)", len(st.AttachedModules))
	}
}

func TestClearAttachedManifestHashes_AllModulesWhenNoIDGiven(t *testing.T) {
	dir := t.TempDir()
	path := writeStateWithStamps(t, dir, map[string]string{"a": "1", "b": "2"})
	r := &Reconciler{cfg: ReconcilerConfig{StatePath: path, OnError: func(string, error) {}}}

	if err := r.ClearAttachedManifestHashes(""); err != nil {
		t.Fatalf("ClearAttachedManifestHashes: %v", err)
	}

	st, err := mount.LoadState(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.LastAttachedManifestHashes) != 0 {
		t.Fatalf("stamps = %v, want empty (a whole-node resync re-materializes every module)", st.LastAttachedManifestHashes)
	}
	if len(st.AttachedModules) != 2 {
		t.Fatal("a whole-node resync must not detach anything either")
	}
}

// An unattached module id must not silently succeed: an operator typing the
// wrong id would otherwise get "resynced: true" and no repair, which is the
// false actuator shape this codebase keeps producing.
func TestClearAttachedManifestHashes_UnattachedModuleIsAnError(t *testing.T) {
	dir := t.TempDir()
	path := writeStateWithStamps(t, dir, map[string]string{"a": "1"})
	r := &Reconciler{cfg: ReconcilerConfig{StatePath: path, OnError: func(string, error) {}}}

	if err := r.ClearAttachedManifestHashes("not-a-module"); err == nil {
		t.Fatal("clearing an unattached module returned nil; the caller will report a resync that cannot happen")
	}
}

// A module attached with NO stamp is the state the budget-abort retry leaves
// behind on purpose. Resyncing it must SUCCEED — erroring would fail the repair
// for a node that is already queued for one, which is exactly the node most
// likely to have an operator running this command.
func TestClearAttachedManifestHashes_AttachedWithoutStampSucceeds(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	st := &mount.State{
		AttachedModules:            []mount.Module{{ID: "budget-aborted", Digest: "sha256:x"}},
		LastAttachedManifestHashes: map[string]string{},
	}
	if err := mount.SaveState(path, st); err != nil {
		t.Fatal(err)
	}
	r := &Reconciler{cfg: ReconcilerConfig{StatePath: path, OnError: func(string, error) {}}}

	if err := r.ClearAttachedManifestHashes("budget-aborted"); err != nil {
		t.Fatalf("resync of an attached-but-unstamped module failed: %v", err)
	}
}
