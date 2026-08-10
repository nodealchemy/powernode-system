package handlers

import (
	"context"
	"errors"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// SyncHandler drives sync_modules, the task system_refresh_instance_modules
// dispatches. Plain RunOnce cannot repair a root whose files were removed
// underneath an UNCHANGED digest (the 2026-08-07 whiteout shape) because
// nothing has drifted — so the operator action that sounds like a resync
// repaired nothing. force_resync clears the attached-state stamps first.
//
// These assert the COLLABORATOR CALL, not the returned status: RunOnce runs
// either way, so an outcome assertion cannot tell a forced resync from an
// ordinary reconcile.
type fakeReconciler struct {
	ranOnce     bool
	clearedWith []string
	clearErr    error
}

func (f *fakeReconciler) RunOnce(_ context.Context) error { f.ranOnce = true; return nil }

func (f *fakeReconciler) ClearAttachedManifestHashes(moduleID string) error {
	f.clearedWith = append(f.clearedWith, moduleID)
	return f.clearErr
}

func runSync(t *testing.T, fake *fakeReconciler, opts map[string]any) (tasks.Result, error) {
	t.Helper()
	h := &SyncHandler{deps: tasks.Dependencies{Reconciler: fake}}
	return h.Execute(context.Background(), &tasks.Task{Command: "sync_modules", Options: opts})
}

func TestSyncHandler_OrdinaryReconcileDoesNotClearStamps(t *testing.T) {
	fake := &fakeReconciler{}

	if _, err := runSync(t, fake, nil); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	if len(fake.clearedWith) != 0 {
		t.Fatalf("an unforced sync cleared stamps %v; every routine 60s-tick sync would re-materialize every module", fake.clearedWith)
	}
	if !fake.ranOnce {
		t.Fatal("RunOnce was not called")
	}
}

func TestSyncHandler_ForceResyncClearsNamedModuleBeforeReconciling(t *testing.T) {
	fake := &fakeReconciler{}

	res, err := runSync(t, fake, map[string]any{"force_resync": true, "module_id": "runtime-go"})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}

	if len(fake.clearedWith) != 1 || fake.clearedWith[0] != "runtime-go" {
		t.Fatalf("clearedWith = %v, want [runtime-go]", fake.clearedWith)
	}
	if !fake.ranOnce {
		t.Fatal("RunOnce was not called after clearing; the stamps would be dropped with nothing re-materializing them")
	}
	if res["status"] != "resynced" || res["scope"] != "single_module" {
		t.Fatalf("result = %v, want status=resynced scope=single_module", res)
	}
}

// The platform may encode JSON options as strings; "true" must not be ignored,
// or the operator's forced resync silently degrades to an ordinary no-op sync.
func TestSyncHandler_ForceResyncAcceptsStringTrue(t *testing.T) {
	fake := &fakeReconciler{}

	if _, err := runSync(t, fake, map[string]any{"force_resync": "true"}); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	if len(fake.clearedWith) != 1 || fake.clearedWith[0] != "" {
		t.Fatalf("clearedWith = %v, want [\"\"] (whole-node resync)", fake.clearedWith)
	}
}

// A failed clear must abort rather than fall through to RunOnce: reconciling
// without having cleared anything reports success while repairing nothing.
func TestSyncHandler_ClearFailureAbortsBeforeReconcile(t *testing.T) {
	fake := &fakeReconciler{clearErr: errors.New("module \"typo\" is not recorded as synced on this node")}

	_, err := runSync(t, fake, map[string]any{"force_resync": true, "module_id": "typo"})

	if err == nil {
		t.Fatal("a failed clear returned nil; the operator is told the node resynced when nothing was queued")
	}
	if fake.ranOnce {
		t.Fatal("RunOnce ran despite the clear failing; that reports a successful resync that did nothing")
	}
}
