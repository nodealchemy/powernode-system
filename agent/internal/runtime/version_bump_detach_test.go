package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// J1 (review round 5 REPLACEMENT review, HIGH, blocks ship): mount.Reconcile
// compares by digest, so a version bump puts the OLD digest in toDetach and
// the NEW one in toAttach. filterUnsafeDetaches lets a version bump's detach
// through unconditionally (it is not a removal) — but nothing upstream of
// the detach loop asked whether the NEW digest could actually attach, and
// RunOnce runs the detach loop BEFORE the attach loop. A version bump whose
// new digest refuses (security drop-in write failure, unapproved privileged
// request, invalid policy) therefore detached the old, WORKING units first
// and then failed to bring up the new ones: the module goes down on EVERY
// node, and — if the module is ops-hub's own rails/postgres on a
// self-hosted node — stays down, because the next tick's
// FetchAssignedModules call goes to the now-dead rails and never reaches
// the attach loop that would have restored it.
//
// filterUnsafeVersionBumpDetaches (selfhost.go) closes this by pre-running
// the SAME security-policy decision attachModule uses, for the NEW
// manifest, before the detach loop runs — and deferring the old digest's
// detach when that decision refuses. This file proves BOTH halves: a
// refused bump must not touch the old, running units, and a successful bump
// must detach+attach exactly as before this fix (the new guard must never
// become an over-cautious "never detach a version bump" no-op).

func versionBumpFixture(digest string) string {
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"%s",
			"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
			"services": [
				{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}
			]
		}
	}`, digest)
}

func versionBumpReconciler(t *testing.T, tmpRoot, statePath string, client *stubModulesClient, runner *mount.RecorderRunner) *Reconciler {
	t.Helper()
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
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
	return r
}

// bumpModuleDigest updates the stub manifest response for moduleID AND
// evicts the on-disk manifest cache LoadOrFetch wrote for the OLD digest —
// ReconcilerConfig.ManifestTTL is 0 in every test in this file (never
// stale), so without evicting the cache the next RunOnce pass would keep
// reading the OLD digest from disk and never observe the bump at all.
func bumpModuleDigest(t *testing.T, manifestRoot, moduleID string, client *stubModulesClient, newDigest string) {
	t.Helper()
	client.responses["/api/v1/system/node_api/modules/"+moduleID] = versionBumpFixture(newDigest)
	if err := os.RemoveAll(filepath.Join(manifestRoot, moduleID)); err != nil {
		t.Fatal(err)
	}
}

func hasSystemctlOp(invocations []mount.Invocation, op, unit string) bool {
	for _, inv := range invocations {
		if inv.Name == "systemctl" && inv.Op == "Run" && containsArg(inv.Args, op) && containsArg(inv.Args, unit) {
			return true
		}
	}
	return false
}

func attachedDigest(t *testing.T, statePath, moduleID string) (digest string, ok bool) {
	t.Helper()
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == moduleID {
			return m.Digest, true
		}
	}
	return "", false
}

func TestVersionBumpDetach_RefusedNewDigestKeepsOldUnitsRunning(t *testing.T) {
	for _, selfHosted := range []bool{false, true} {
		t.Run(fmt.Sprintf("selfHosted=%v", selfHosted), func(t *testing.T) {
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
			runner := &mount.RecorderRunner{}
			r := versionBumpReconciler(t, tmpRoot, statePath, client, runner)
			r.selfHostLatched = selfHosted

			unit := lifecycle.UnitName("m1", "app")

			// PASS 1: clean attach at digest abc123.
			if err := r.RunOnce(context.Background()); err != nil {
				t.Fatalf("RunOnce pass 1: %v", err)
			}
			if !hasSystemctlOp(runner.Invocations, "start", unit) {
				t.Fatalf("pass 1: expected %s to start, invocations: %v", unit, runner.Invocations)
			}
			if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "abc123" {
				t.Fatalf("pass 1: expected m1 attached at abc123, got digest=%q ok=%v", digest, ok)
			}

			// Force the NEW digest's drop-in write to fail, then bump.
			unitDropInDir := filepath.Join(dropIns, unit+".d")
			blocked := filepath.Join(unitDropInDir, "capabilities.conf")
			if err := os.RemoveAll(blocked); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(blocked, 0o755); err != nil {
				t.Fatal(err)
			}
			bumpModuleDigest(t, filepath.Join(tmpRoot, "manifests"), "m1", client, "def456")

			pass2Start := len(runner.Invocations)
			if err := r.RunOnce(context.Background()); err != nil {
				t.Fatalf("RunOnce pass 2: %v", err)
			}
			pass2Invocations := runner.Invocations[pass2Start:]

			if hasSystemctlOp(pass2Invocations, "stop", unit) {
				t.Errorf("J1 REGRESSION: pass 2 (selfHosted=%v) stopped %s even though the new digest's attach would fail closed — old, working units must stay up: %v",
					selfHosted, unit, pass2Invocations)
			}
			if got := r.SecurityFailClosedUnits(); !containsArg(got, unit) {
				t.Errorf("pass 2: expected %s in SecurityFailClosedUnits() (the refusal must still be recorded), got %v", unit, got)
			}
			if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "abc123" {
				t.Errorf("J1 REGRESSION: pass 2 (selfHosted=%v) must leave m1 attached at the OLD digest abc123 (never detached ahead of a refused new attach), got digest=%q ok=%v",
					selfHosted, digest, ok)
			}

			// PASS 3: unblock — the bump should now go through normally.
			if err := os.RemoveAll(blocked); err != nil {
				t.Fatal(err)
			}
			pass3Start := len(runner.Invocations)
			if err := r.RunOnce(context.Background()); err != nil {
				t.Fatalf("RunOnce pass 3: %v", err)
			}
			pass3Invocations := runner.Invocations[pass3Start:]

			if !hasSystemctlOp(pass3Invocations, "start", unit) {
				t.Errorf("pass 3: expected %s to (re)start now that the drop-in write succeeds, invocations: %v", unit, pass3Invocations)
			}
			if got := r.SecurityFailClosedUnits(); len(got) != 0 {
				t.Errorf("pass 3: SecurityFailClosedUnits() must clear once the bump succeeds, got %v", got)
			}
			if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "def456" {
				t.Errorf("pass 3: expected m1 attached at the NEW digest def456 once its attach stops refusing, got digest=%q ok=%v", digest, ok)
			}
		})
	}
}

// The other half of J1: the new guard must not turn into "never detach a
// version bump" — a bump whose new digest attaches cleanly must still
// detach the old digest and attach+start the new one in the SAME tick, the
// behavior that predates this fix.
func TestVersionBumpDetach_SuccessfulBumpStillDetachesAndAttaches(t *testing.T) {
	for _, selfHosted := range []bool{false, true} {
		t.Run(fmt.Sprintf("selfHosted=%v", selfHosted), func(t *testing.T) {
			tmpRoot := t.TempDir()
			statePath := filepath.Join(t.TempDir(), "state.json")
			t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))
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
			runner := &mount.RecorderRunner{}
			r := versionBumpReconciler(t, tmpRoot, statePath, client, runner)
			r.selfHostLatched = selfHosted

			unit := lifecycle.UnitName("m1", "app")

			if err := r.RunOnce(context.Background()); err != nil {
				t.Fatalf("RunOnce pass 1: %v", err)
			}

			bumpModuleDigest(t, filepath.Join(tmpRoot, "manifests"), "m1", client, "def456")
			pass2Start := len(runner.Invocations)
			if err := r.RunOnce(context.Background()); err != nil {
				t.Fatalf("RunOnce pass 2: %v", err)
			}
			pass2Invocations := runner.Invocations[pass2Start:]

			if !hasSystemctlOp(pass2Invocations, "stop", unit) {
				t.Errorf("J1 REGRESSION: a clean version bump (selfHosted=%v) must still stop+detach the old digest's units, invocations: %v", selfHosted, pass2Invocations)
			}
			if !hasSystemctlOp(pass2Invocations, "start", unit) {
				t.Errorf("a clean version bump (selfHosted=%v) must (re)start the unit under the new digest, invocations: %v", selfHosted, pass2Invocations)
			}
			if got := r.SecurityFailClosedUnits(); len(got) != 0 {
				t.Errorf("a clean version bump must not record any fail-closed refusal, got %v", got)
			}
			if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "def456" {
				t.Errorf("a clean version bump must leave m1 attached at the NEW digest def456, got digest=%q ok=%v", digest, ok)
			}
		})
	}
}
