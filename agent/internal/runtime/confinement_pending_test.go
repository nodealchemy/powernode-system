package runtime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// X1 (IMP-caef5c00d63f round X, HIGH): the pending-confinement state must be
// PERSISTED and LEVEL-TRIGGERED, not re-derived per tick from W1's own
// edge-triggered changedUnits signal — see mount.Module.PendingConfinementUnits'
// own doc for the full enumeration of ways the edge gets lost. These tests
// pin the four failure modes team-lead's review named explicitly. X5's own
// "report via noteUnconverged, not a bare OnError" fix (same round) is
// verified here too, since ConvergenceFailures() visibility is the natural
// way to observe X1's own set surviving across ticks.

// TestReconcile_SelfHostedConfinementPendingPersistsAcrossTicks is the core
// regression: a self-hosted node's own confinement-pending withhold used to
// last exactly ONE tick (the probe from team-lead's review: "tick3
// stamped=true pendingSignal=false") — tick N+1's own write reports
// changed=false (the bytes already match what tick N wrote), so a design
// that only consults THIS tick's own changedUnits re-stamps the module
// converged while the running process still holds its OLD capabilities.
func TestReconcile_SelfHostedConfinementPendingPersistsAcrossTicks(t *testing.T) {
	r, client, runner, statePath, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 1: %v", err)
	}
	r.selfHostLatched = true

	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 2: %v", err)
	}

	for tick := 3; tick <= 4; tick++ {
		var onErrors []string
		r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

		if err := r.RunOnce(context.Background()); err != nil {
			t.Fatalf("tick %d: %v", tick, err)
		}
		if !convergenceFailuresContain(onErrors, "reconciler:confinement_pending_restart") || !convergenceFailuresContain(onErrors, unit) {
			t.Errorf("tick %d: X1 REGRESSION: expected confinement_pending_restart naming %s reported EVERY tick, got onErrors=%v", tick, unit, onErrors)
		}
		if cf := r.ConvergenceFailures(); !convergenceFailuresContain(cf, "reconciler:confinement_pending_restart") {
			t.Errorf("tick %d: X5 REGRESSION: expected ConvergenceFailures() to carry the pending confinement, got %v", tick, cf)
		}
		st, err := mount.LoadState(statePath)
		if err != nil {
			t.Fatalf("tick %d: LoadState: %v", tick, err)
		}
		if _, stamped := st.LastAttachedManifestHashes["m1"]; stamped {
			t.Errorf("tick %d: X1 REGRESSION: m1 re-stamped converged while a confinement restart is still pending", tick)
		}
		if len(st.AttachedModules) != 1 || len(st.AttachedModules[0].PendingConfinementUnits) == 0 {
			t.Errorf("tick %d: X1 REGRESSION: expected PendingConfinementUnits to persist, got %+v", tick, st.AttachedModules)
		}
	}
}

// TestReconcile_ConfinementPendingSurvivesAgentRestart proves the set lives
// in state.json, not merely in the running process's memory: a fresh
// Reconciler pointed at the SAME statePath must still see it.
func TestReconcile_ConfinementPendingSurvivesAgentRestart(t *testing.T) {
	r, client, runner, statePath, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 1: %v", err)
	}
	r.selfHostLatched = true
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 2: %v", err)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if len(st.AttachedModules) != 1 || len(st.AttachedModules[0].PendingConfinementUnits) == 0 {
		t.Fatalf("precondition: expected a persisted pending-confinement set after tick 2, got %+v", st.AttachedModules)
	}

	// Simulate an agent restart: a brand-new Reconciler that only ever reads
	// state.json fresh off disk — nothing here carries the old process's
	// in-memory state forward.
	tmpRoot := filepath.Dir(statePath)
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	freshRunner := &mount.RecorderRunner{StubOutput: map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}}
	r2, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    freshRunner,
		Layout:         layout,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler (restart): %v", err)
	}
	r2.selfHostLatched = true
	var onErrors []string
	r2.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	if err := r2.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 3 (post-restart): %v", err)
	}

	if !convergenceFailuresContain(onErrors, "reconciler:confinement_pending_restart") || !convergenceFailuresContain(onErrors, unit) {
		t.Errorf("X1 REGRESSION: pending confinement did not survive a simulated agent restart, onErrors=%v", onErrors)
	}
}

// TestReconcile_DaemonReloadFailureThenSuccessAppliesRestart is X1's third
// named case: a daemon-reload failure must leave the unit pending (not
// stamped), and a LATER tick where the reload stops failing must actually
// reload+restart, picking the change up rather than losing it because the
// bytes already matched by then.
func TestReconcile_DaemonReloadFailureThenSuccessAppliesRestart(t *testing.T) {
	r, client, runner, statePath, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 1: %v", err)
	}
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	runner.StubErr = map[string]error{"systemctl daemon-reload": errors.New("stub: daemon-reload failed")}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 2 (reload fails): %v", err)
	}
	if hasSystemctlOp(runner.Invocations, "restart", unit) {
		t.Error("a failed daemon-reload must never be followed by a reported restart")
	}
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if _, stamped := st.LastAttachedManifestHashes["m1"]; stamped {
		t.Fatal("X1 REGRESSION: module stamped converged despite a daemon-reload failure")
	}
	if len(st.AttachedModules) != 1 || len(st.AttachedModules[0].PendingConfinementUnits) == 0 {
		t.Fatalf("X1 REGRESSION: expected the change to stay pending after a reload failure, got %+v", st.AttachedModules)
	}

	// TICK 3: the reload stops failing. The write itself reports changed=false
	// this time (identical bytes), so only the PERSISTED pending set can
	// still trigger a retry.
	runner.StubErr = nil
	preInvocations := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 3 (reload succeeds): %v", err)
	}
	tick3 := runner.Invocations[preInvocations:]
	if !hasSystemctlOp(tick3, "restart", unit) {
		t.Errorf("X1 REGRESSION: expected the retried tick to reload+restart once the reload stopped failing, invocations=%v", tick3)
	}
	st, err = mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if _, stamped := st.LastAttachedManifestHashes["m1"]; !stamped {
		t.Error("expected m1 stamped converged once the confinement change actually applied")
	}
	if len(st.AttachedModules) != 1 || len(st.AttachedModules[0].PendingConfinementUnits) != 0 {
		t.Errorf("expected PendingConfinementUnits cleared once the restart succeeded, got %+v", st.AttachedModules)
	}
}

// TestReconcile_ConfinementRestartFailureIsNotStampedConverged is X5
// (IMP-caef5c00d63f round X, MEDIUM, invariant 2): a confinement-only
// restart that itself FAILS (e.g. the narrower caps break the unit's own
// start) must not be stamped converged, and must surface through
// ConvergenceFailures() — not just a bare OnError call nothing else
// consults.
func TestReconcile_ConfinementRestartFailureIsNotStampedConverged(t *testing.T) {
	r, client, runner, statePath, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 1: %v", err)
	}
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	runner.StubErr = map[string]error{"systemctl restart " + unit: errors.New("stub: restart failed (unit refused to start under the narrower caps)")}

	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("tick 2 (restart fails): %v", err)
	}

	if !convergenceFailuresContain(onErrors, "reconciler:confinement_pending_restart") || !convergenceFailuresContain(onErrors, unit) {
		t.Errorf("X5 REGRESSION: expected a failed confinement restart reported via confinement_pending_restart, got onErrors=%v", onErrors)
	}
	if cf := r.ConvergenceFailures(); !convergenceFailuresContain(cf, "reconciler:confinement_pending_restart") {
		t.Errorf("X5 REGRESSION: expected ConvergenceFailures() to carry the failed restart (invariant 2 — a task gate consulting this channel must see it), got %v", cf)
	}
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if _, stamped := st.LastAttachedManifestHashes["m1"]; stamped {
		t.Error("X5 REGRESSION: m1 stamped converged despite the confinement restart itself failing")
	}
}

// TestResolvePendingConfinementUnits_StepErrKeepsUnitPendingRegardlessOfLaterActiveRead
// is X5's own low-level, precisely-targeted complement to the RunOnce-level
// test above: a unit whose OWN restart/start attempt reported a StepErr must
// stay pending NO MATTER what a later is-active probe says — a failed
// restart can plausibly leave the unit inactive (stop succeeded, start
// failed), and resolvePendingConfinementUnits must not read that as
// "confirmed inactive, resolved" the way it correctly does for a unit that
// was never touched by an error at all.
func TestResolvePendingConfinementUnits_StepErrKeepsUnitPendingRegardlessOfLaterActiveRead(t *testing.T) {
	unit := "powernode-m1-app.service"
	r := &Reconciler{cfg: ReconcilerConfig{
		MountRunner: &mount.RecorderRunner{
			StubOutput: map[string][]byte{"systemctl is-active " + unit: []byte("inactive\n")},
		},
	}}
	results := []lifecycle.AttachResult{{Unit: unit, StepErr: errors.New("systemctl restart " + unit + ": exit status 1")}}

	pending := r.resolvePendingConfinementUnits(context.Background(), []string{unit}, results, nil)
	if len(pending) != 1 || pending[0] != unit {
		t.Errorf("X5 REGRESSION: a StepErr'd unit must stay pending regardless of a later is-active read, got %v", pending)
	}
}

// TestReconcile_HotReconcileRefusalLeavesConfinementPending is X1's fourth
// named case: a materialization refusal right after attachModule wrote a
// genuine (first-ever) confinement change must not lose that change — the
// reattach loop used to persist nothing until it reached
// attachModuleServices, which a hot-reconcile refusal `continue`s past
// entirely.
func TestReconcile_HotReconcileRefusalLeavesConfinementPending(t *testing.T) {
	r, layout, _, statePath := refusalFixture(t)
	oversizeModulePayload(t, layout.ModuleMountPath("abc123"))
	constantFree(t, 600_000)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if len(st.AttachedModules) != 1 || len(st.AttachedModules[0].PendingConfinementUnits) == 0 {
		t.Fatalf("X1 REGRESSION: expected the confinement change written before the materialization refusal to persist as pending, got %+v", st.AttachedModules)
	}
}
