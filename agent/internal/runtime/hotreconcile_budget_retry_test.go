package runtime

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// SyncModuleFiles' doc says a budget-aborted materialization "re-converges on
// the next tick or reboot". The next-tick half was false.
//
// RunOnce stamps current.LastAttachedManifestHashes[mod.ID] BEFORE calling
// hotReconcileIfNeeded, and hotReconcileIfNeeded reported nothing back, so a
// budget abort left the module recorded as fully synced. The reattach gate
// (`current.LastAttachedManifestHashes[mod.ID] != fresh`) then saw a matching
// hash on every subsequent tick and never retried — the reconciler:recompose_budget
// signal fired once and went quiet, which reads to an operator as resolved
// rather than stuck. Observed on dev-cell: two ENOSPC events a minute apart,
// then nothing for two hours with a 290MB payload still unmaterialized.
//
// The retry lever is the manifest-hash stamp: clearing it puts the module back
// into toReattach on the next tick, so the sync is attempted again once the
// scratch has room. The mount itself stays attached, which is correct — the
// erofs layer really is attached; only the file materialization was refused.
func budgetFixture(t *testing.T) (*Reconciler, mount.Layout, *[]string) {
	t.Helper()
	layout := mount.Layout{
		ModulesMountRoot: t.TempDir(),
		Root:             t.TempDir(),
	}
	var signals []string
	r := &Reconciler{cfg: ReconcilerConfig{
		Layout:  layout,
		OnError: func(kind string, _ error) { signals = append(signals, kind) },
	}}
	return r, layout, &signals
}

// Fills the module's mount dir with a payload far larger than the free-space
// floor we pass, so SyncModuleFiles aborts with ErrScratchBudget.
func writeOversizePayload(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "usr", "local"), 0o755); err != nil {
		t.Fatal(err)
	}
	blob := make([]byte, 256*1024)
	if err := os.WriteFile(filepath.Join(dir, "usr", "local", "big.bin"), blob, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestHotReconcile_BudgetAbortRequestsRetry(t *testing.T) {
	if pivotAwareRootMode() != lifecycle.RootModeNative {
		t.Skip("hot reconcile only runs in native root mode")
	}
	r, layout, signals := budgetFixture(t)
	mod := mount.Module{ID: "runtime-go", Digest: "sha256:budget"}
	writeOversizePayload(t, layout.ModuleMountPath(mod.Digest))

	// Pins the MID-WALK abort arm specifically. A floor no filesystem can
	// satisfy no longer reaches it: escalateIfHotRungTooSmall now prices the
	// whole diff first and refuses before the walk (see
	// TestHotReconcile_OversizeModuleEscalatesInsteadOfRatcheting). The arm
	// under test here is the one that survives that pre-flight — the scratch
	// filled up between the plan and the copy — and it must still request the
	// retry, because the plan is an estimate and the guard is the backstop.
	r.cfg.ScratchMinFreeBytes = 1000
	preflightPassesThenScratchVanishes(t, 1<<20, 1000)

	mf := &manifest.Manifest{}
	retry := r.hotReconcileIfNeeded(mod, mf, false, nil, mount.ModuleStack{mod})

	if !retry {
		t.Fatalf("budget abort reported retry=false; the caller will keep the manifest-hash stamp and the module is never re-synced")
	}
	found := false
	for _, s := range *signals {
		if s == "reconciler:recompose_budget" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected reconciler:recompose_budget signal, got %v", *signals)
	}
}

// A sync that had nothing to do must NOT request a retry, or every tick
// re-enters toReattach forever. This is the example that fails if the retry
// flag is wired as "anything other than complete success".
func TestHotReconcile_NoRetryWhenNotApplicable(t *testing.T) {
	r, _, _ := budgetFixture(t)
	mod := mount.Module{ID: "quiet", Digest: "sha256:quiet"}

	// stateWasEmpty: a first boot attaches everything; there is no hot sync.
	if r.hotReconcileIfNeeded(mod, &manifest.Manifest{}, true, nil, mount.ModuleStack{mod}) {
		t.Fatal("stateWasEmpty requested a retry; that would re-reattach on every tick")
	}
	// A reboot_required module cannot be applied hot. Retrying would spam the
	// reboot_pending signal every tick without ever making progress — the
	// operator's reboot is the only thing that resolves it.
	if r.hotReconcileIfNeeded(mod, &manifest.Manifest{RebootRequired: true}, false, nil, mount.ModuleStack{mod}) {
		t.Fatal("reboot_required requested a retry; the reboot is the operator's action, not the reconciler's")
	}
}
