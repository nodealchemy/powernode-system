package handlers

import (
	"context"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// IMP-f1c1e6d61104 — a reconcile pass that did not converge the desired module
// set must FAIL apply_config rather than complete it.
//
// Why this matters on the server: ConfigDriftSensor suppresses
// `system.config_drift` for a node once a COMPLETED apply_config exists for it.
// RunOnce returns an error only for whole-pass failures; every per-module
// failure (reboot_required declining live materialization, a scratch-budget
// abort, a copy error, an unpublished digest) reports through OnError, which in
// service mode is a stderr printf the platform never sees. So the task
// completed, the sensor went quiet, and the node had not converged — silent
// over-suppression, which is the dangerous direction.
type convergenceFake struct {
	failures []string
}

func (f *convergenceFake) RunOnce(_ context.Context) error { return nil }

func (f *convergenceFake) ClearAttachedManifestHashes(_ string) error { return nil }

func (f *convergenceFake) ConvergenceFailures() []string { return f.failures }

func runConvergence(t *testing.T, fake *convergenceFake) (tasks.Result, error) {
	t.Helper()
	h := &SyncHandler{deps: tasks.Dependencies{Reconciler: fake}}
	return h.Execute(context.Background(), &tasks.Task{Command: "apply_config"})
}

func TestSyncHandler_FailsWhenAModuleDidNotConverge(t *testing.T) {
	fake := &convergenceFake{failures: []string{
		"reconciler:reboot_pending [mod-base-os]: module changed but reboot_required=true",
	}}

	res, err := runConvergence(t, fake)

	if err == nil {
		t.Fatal("apply_config completed despite an unconverged module — the server suppresses " +
			"config_drift on a completed apply, so this silences real drift")
	}
	if res != nil {
		t.Errorf("expected no result alongside the failure, got %v", res)
	}
	if !strings.Contains(err.Error(), "reboot_pending") ||
		!strings.Contains(err.Error(), "mod-base-os") {
		t.Errorf("failure must name the stage and module so the operator can act on it; got %q", err)
	}
}

func TestSyncHandler_ReportsEveryUnconvergedModule(t *testing.T) {
	fake := &convergenceFake{failures: []string{
		"reconciler:reboot_pending [mod-a]: needs reboot",
		"reconciler:recompose_budget [mod-b]: scratch exhausted",
		"reconciler:no_digest [mod-c]: not published",
	}}

	_, err := runConvergence(t, fake)

	if err == nil {
		t.Fatal("expected failure")
	}
	for _, want := range []string{"mod-a", "mod-b", "mod-c"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("failure dropped %s — an operator fixing only the first would think it done: %q", want, err)
		}
	}
	if !strings.Contains(err.Error(), "3 module(s)") {
		t.Errorf("failure should state how many modules did not converge; got %q", err)
	}
}

// CONTROL, and the one that fails if the change over-corrects: a pass with no
// convergence failures must still COMPLETE. Over-failing apply_config would
// un-suppress every node at once — the ~500/tick flood IMP-a99067b836bf
// removed — which is exactly what this change must not do.
func TestSyncHandler_CompletesWhenEverythingConverged(t *testing.T) {
	fake := &convergenceFake{failures: nil}

	res, err := runConvergence(t, fake)

	if err != nil {
		t.Fatalf("a converged pass must complete and suppress drift; got %v", err)
	}
	if res["status"] != "reconciled" {
		t.Errorf("expected status reconciled, got %v", res["status"])
	}
}

// CONTROL: a reconciler that cannot report convergence (the existing fakes, and
// any older collaborator) behaves exactly as before rather than failing closed.
// Failing closed here would break every caller that has not adopted the
// interface.
func TestSyncHandler_UnreportingReconcilerIsUnchanged(t *testing.T) {
	h := &SyncHandler{deps: tasks.Dependencies{Reconciler: &fakeReconciler{}}}

	res, err := h.Execute(context.Background(), &tasks.Task{Command: "apply_config"})

	if err != nil {
		t.Fatalf("a reconciler without ConvergenceFailures must behave as before; got %v", err)
	}
	if res["status"] != "reconciled" {
		t.Errorf("expected status reconciled, got %v", res["status"])
	}
}
