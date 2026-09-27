package runtime

import (
	"context"
	"os"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// X2 (IMP-caef5c00d63f round X, MEDIUM): every attachModule call site must
// thread its own changedUnits into the matching attachModuleServices call —
// W1's own fresh-attach and AttachOne paths passed nil unconditionally, and
// the reattach loop's never-touched-revert branch, while already correct,
// had no test proving it (mutant M6 survived the round-W review).

// TestReconcile_FreshAttachRestartsAPreStartedUnitWithStaleConfinement is X2
// (A3): "on a pivot node, compose already started the units, state is empty
// or was rebased" — the fresh-attach loop (attachedNow[mod.ID] false) can
// still meet an ALREADY-RUNNING, ALREADY byte-identical unit body (compose
// wrote it), so writeIfChanged's own Skipped=true means the unit-body signal
// alone can't trigger a restart — only a THREADED changedUnits (not nil) can,
// via the SAME confinementChanged path a reattach already gets. Pre-seeds
// the unit file with the EXACT body the renderer would produce (simulating
// compose) and stubs the unit active, so the only remaining signal that can
// trigger a restart is attachModule's own (first-ever) capability-drop-in
// write.
func TestReconcile_FreshAttachRestartsAPreStartedUnitWithStaleConfinement(t *testing.T) {
	r, _, runner, _ := firstAttachRefusalFixture(t)
	t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))
	unit := lifecycle.UnitName("m1", "qga")

	svc := manifest.Service{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always"}
	body := lifecycle.RenderUnitModeGraph(svc, "m1", lifecycle.RootModeNative, nil)
	if err := os.MkdirAll(lifecycle.UnitDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(lifecycle.UnitPath("m1", "qga"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if !hasSystemctlOp(runner.Invocations, "restart", unit) {
		t.Errorf("X2 REGRESSION: expected the fresh-attach path to restart a pre-started unit whose confinement attachModule just wrote, invocations=%v", runner.Invocations)
	}
}

// TestAttachOne_RestartsAPreStartedUnitWithStaleConfinement is X2's AttachOne
// sibling: the CLI attach path threaded nil into attachModuleServices
// unconditionally, so even a unit AttachOne finds already active with a body
// that doesn't need rewriting never got its freshly-written confinement
// change applied.
func TestAttachOne_RestartsAPreStartedUnitWithStaleConfinement(t *testing.T) {
	r, _, runner, _ := firstAttachRefusalFixture(t)
	t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))
	unit := lifecycle.UnitName("m1", "qga")

	svc := manifest.Service{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always"}
	body := lifecycle.RenderUnitModeGraph(svc, "m1", lifecycle.RootModeNative, nil)
	if err := os.MkdirAll(lifecycle.UnitDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(lifecycle.UnitPath("m1", "qga"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}

	status, err := r.AttachOne(context.Background(), "m1")
	if err != nil {
		t.Fatalf("AttachOne: %v", err)
	}
	if status != "attached" {
		t.Fatalf("AttachOne status = %q, want %q", status, "attached")
	}
	if !hasSystemctlOp(runner.Invocations, "restart", unit) {
		t.Errorf("X2 REGRESSION: expected AttachOne to restart a pre-started unit whose confinement attachModule just wrote, invocations=%v", runner.Invocations)
	}
}

// TestReconcile_NeverTouchedRevertAppliesAConcurrentConfinementChange is X2's
// third named site (reconcile.go's "never touched" revert branch — mutant
// M6 survived the round-W review): a revert episode where the abandoned
// digest never touched anything falls through to an ORDINARY, unforced
// attachModuleServices call — but the STABLE digest's own manifest can
// ITSELF carry a genuine, concurrent capabilities-list edit on the very
// same tick the revert resolves. That edit's changedUnits must still reach
// attachModuleServices, not silently pass nil, or the confinement change
// sits on disk unapplied even though the tick reports success.
func TestReconcile_NeverTouchedRevertAppliesAConcurrentConfinementChange(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	r.cfg.Puller = &failingPuller{PullerAPI: r.cfg.Puller, failDigest: "d2"}
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (step 1 refused): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("precondition: expected PendingDigest=d2 after the step-1 refusal, got %q ok=%v", pd, ok)
	}

	// Revert to d1 — but ALSO widen d1's own declared capabilities in the
	// SAME manifest fetch, so the never-touched branch's own attachModule
	// call reports a genuine changedUnits for this tick, independent of the
	// revert bookkeeping itself.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN", "CAP_NET_ADMIN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	pass3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3 (revert + concurrent confinement edit): %v", err)
	}
	pass3 := runner.Invocations[pass3Start:]
	if !hasSystemctlOp(pass3, "restart", appUnit) {
		t.Errorf("M6 REGRESSION: expected the never-touched revert's own concurrent confinement change to restart %s, invocations: %v", appUnit, pass3)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("pass 3: expected m1 at d1, got digest=%q ok=%v", digest, ok)
	}
}
