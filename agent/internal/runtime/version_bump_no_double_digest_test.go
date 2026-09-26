package runtime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

func countDigestsForID(t *testing.T, statePath, moduleID string) int {
	t.Helper()
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	n := 0
	for _, m := range st.AttachedModules {
		if m.ID == moduleID {
			n++
		}
	}
	return n
}

// K3 (review round 6, MEDIUM-HIGH): before this fix, a deferred bump's new
// digest was STILL attempted for real in the same tick's attach loop (the
// pre-check deferring the detach did not stop RunOnce from also trying the
// real attach). The review's repro: a transient pre-check failure defers the
// old digest's detach, but the REAL attach then succeeds anyway (a race, or
// simply the pre-check and the real write disagreeing) — leaving BOTH
// digests in state.json. The NEXT tick's detach of the stale old entry then
// calls lifecycle.DetachServices using THAT tick's (new) manifest's service
// names — and since unit names never depend on digest, that stops the
// CURRENTLY RUNNING (new) units under the guise of removing a stale
// duplicate.
//
// The fix (RunOnce strips a deferred module's ID out of toAttach before the
// attach loop runs) makes the double-attach structurally impossible — this
// test pins the INVARIANT across three ticks: a deferred bump never
// produces two digests of one module ID in state.json, and never stops a
// unit that a later tick would misidentify as "the stale one".
func TestVersionBumpDetach_NeverProducesTwoDigestsAcrossThreeTicks(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(t.TempDir(), "state.json")
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{
			"success": true,
			"data": {"modules": [
				{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}
			]}
		}`,
		"/api/v1/system/node_api/modules/m1": versionBumpFixture("abc123"),
	}}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	runner := &mount.RecorderRunner{}
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}

	unit := lifecycle.UnitName("m1", "app")

	// TICK 1: clean attach.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}
	if n := countDigestsForID(t, statePath, "m1"); n != 1 {
		t.Fatalf("tick 1: expected exactly 1 digest for m1, got %d", n)
	}

	// TICK 2: bump, force the pre-check to refuse (deferred).
	unitDropInDir := filepath.Join(dropIns, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	bumpModuleDigest(t, filepath.Join(tmpRoot, "manifests"), "m1", client, "def456")

	tick2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	tick2Invocations := runner.Invocations[tick2Start:]
	if n := countDigestsForID(t, statePath, "m1"); n != 1 {
		t.Errorf("K3 REGRESSION: tick 2 (deferred bump) must never produce two digests for m1, got %d", n)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "abc123" {
		t.Errorf("tick 2: expected m1 to remain at the OLD digest abc123 while deferred, got digest=%q ok=%v", digest, ok)
	}
	if hasSystemctlOp(tick2Invocations, "stop", unit) {
		t.Errorf("K3 REGRESSION: tick 2 must not stop %s while the bump is deferred: %v", unit, tick2Invocations)
	}
	// K3's actual mechanism: RunOnce strips a deferred module's ID out of
	// toAttach before the attach loop runs, so attachModule (and therefore
	// mountModuleArtifact) is called for the new digest AT MOST ONCE this
	// tick — from prefetchNewArtifacts, which runs unconditionally before
	// the deferral decision even exists. A regression that let the real
	// attach loop ALSO try the deferred module would call mountModuleArtifact
	// a SECOND time for the identical digest in the SAME tick.
	newMountCalls := 0
	for _, inv := range tick2Invocations {
		if inv.Name == "mount" && containsArg(inv.Args, "-t") {
			for _, a := range inv.Args {
				if filepath.Base(a) == "def456.erofs" {
					newMountCalls++
				}
			}
		}
	}
	if newMountCalls != 1 {
		t.Errorf("K3 REGRESSION: expected exactly 1 mount attempt for the deferred new digest this tick (prefetch only — the real attach loop must never also try it), got %d: %v", newMountCalls, tick2Invocations)
	}

	// TICK 3: unblock — the bump completes normally, exactly once.
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	tick3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3: %v", err)
	}
	tick3Invocations := runner.Invocations[tick3Start:]
	if n := countDigestsForID(t, statePath, "m1"); n != 1 {
		t.Errorf("K3 REGRESSION: tick 3 (completed bump) must leave exactly 1 digest for m1, got %d", n)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "def456" {
		t.Errorf("tick 3: expected m1 attached at the NEW digest def456, got digest=%q ok=%v", digest, ok)
	}
	// The unit should stop (old) and start (new) EXACTLY ONCE each this
	// tick — a lingering double-attach would show up as either a stop the
	// module never should have needed, or a second, redundant stop/start
	// pair.
	stops, starts := 0, 0
	for _, inv := range tick3Invocations {
		if inv.Name == "systemctl" && inv.Op == "Run" && containsArg(inv.Args, unit) {
			if containsArg(inv.Args, "stop") {
				stops++
			}
			if containsArg(inv.Args, "start") {
				starts++
			}
		}
	}
	if stops != 1 || starts != 1 {
		t.Errorf("K3 REGRESSION: expected exactly one stop and one start of %s on the completing tick, got stops=%d starts=%d: %v", unit, stops, starts, tick3Invocations)
	}
}
