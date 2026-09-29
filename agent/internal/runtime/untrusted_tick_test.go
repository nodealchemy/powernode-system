package runtime

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// IMP-1023e79cc82d — a tick whose answer from the platform cannot be trusted
// must retain what is attached, never detach it. Each test below drives one
// such input through RunOnce on a node that is NOT self-hosted (the one
// configuration with no other guard standing in the way).

// An attached module whose assignment arrives with NO digest is not a removal:
// the module is still assigned, and the platform merely failed to say which
// build it is (an unpublished or non-erofs artifact). It was detached, along
// with its declared users, because only a fetch failure was protected.
func TestRunOnce_DigestlessAssignmentRetainsTheAttachedModule(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 1 (attach m1): %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("precondition: m1 must be attached at d1, got %q ok=%v", digest, ok)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	pre := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2 (m1 digestless): %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("a digestless assignment must not detach m1: attached digest = %q ok=%v", digest, ok)
	}
	if hasSystemctlOp(runner.Invocations[pre:], "stop", appUnit) {
		t.Errorf("a digestless assignment must not stop %s, invocations: %v", appUnit, runner.Invocations[pre:])
	}
}

// success:true with an EMPTY module list, while modules are attached, must not
// detach all of them. The platform has no marker that separates "the operator
// unassigned everything" from a degraded answer (a wrong account, a database
// that answered with nothing), so the agent treats it as untrusted and keeps
// what it has; per-module removal stays available through `powernode-agent
// detach`. Detaching everything is also what rendered /etc/passwd down to the
// baseline in the 2026-09-22 outage.
func TestRunOnce_EmptyAssignmentListRetainsEveryAttachedModule(t *testing.T) {
	r, client, runner, _, statePath, _, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")
	var signals []string
	r.cfg.OnError = func(stage string, err error) { signals = append(signals, stage) }

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 1 (attach m1): %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("precondition: m1 must be attached at d1, got %q ok=%v", digest, ok)
	}

	client.responses["/api/v1/system/node_api/modules"] = `{"success": true, "data": {"modules": [], "count": 0}}`
	pre := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2 (empty assignment list): %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("an empty assignment list must not detach the attached module: digest = %q ok=%v", digest, ok)
	}
	if hasSystemctlOp(runner.Invocations[pre:], "stop", appUnit) {
		t.Errorf("an empty assignment list must not stop %s, invocations: %v", appUnit, runner.Invocations[pre:])
	}
	if !strings.Contains(strings.Join(signals, " "), "reconciler:detach_deferred_empty_assignment") {
		t.Errorf("refusing the detach must be surfaced as reconciler:detach_deferred_empty_assignment, got %v", signals)
	}
}

// When the identity render is SKIPPED (an attached module's manifest cannot be
// resolved, so the users/groups it declares cannot be rendered), the attach and
// reattach loops must not run either. Before this they still started a new
// module's units, and units a manifest-only edit introduced, against users that
// were never rendered (217/USER), and stamped the attach, so nothing retried
// it. On a skipped tick the module stays pending and the next trusted tick
// attaches it.
func TestRunOnce_RenderSkippedTickDoesNotAttachOrReattach(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	m3Unit := lifecycle.UnitName("m3", "app")
	m1WorkerUnit := lifecycle.UnitName("m1", "old-worker")
	const m2Digest = `"digest":"e1"`
	m2Body := `{"success": true,"data": {"id":"m2","name":"other","priority":100,"effective_priority":100,` + m2Digest + `,
		"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
		"users": [{"name":"pguser","uid":6001,"primary_gid":6001,"primary_group":"pguser","shell":"/bin/false","home":"/home/pguser"}],
		"groups": [{"name":"pguser","gid":6001}], "services": []}}`
	m3Body := `{"success": true,"data": {"id":"m3","name":"newmod","priority":100,"effective_priority":100,"digest":"f1",
		"users": [{"name":"newuser","uid":6002,"primary_gid":6002,"primary_group":"newuser","shell":"/bin/false","home":"/home/newuser"}],
		"groups": [{"name":"newuser","gid":6002}],
		"services": [` + upgradeAppService + `]}}`
	listWithM3 := `{"success": true,"data": {"modules": [
		{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true},
		{"id":"m2", "name":"other", "priority":100, "effective_priority":100, "has_data_file":true},
		{"id":"m3", "name":"newmod", "priority":100, "effective_priority":100, "has_data_file":true}]}}`

	client.responses["/api/v1/system/node_api/modules"] = `{"success": true,"data": {"modules": [
		{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true},
		{"id":"m2", "name":"other", "priority":100, "effective_priority":100, "has_data_file":true}]}}`
	client.responses["/api/v1/system/node_api/modules/m2"] = m2Body
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 1 (attach m1 + m2): %v", err)
	}

	// Tick 2: m2's manifest is genuinely unresolvable (no fetch, no cache, no
	// attached snapshot, no breadcrumb) => the render is skipped. Meanwhile m3
	// is newly assigned and m1's manifest gained a service (same digest).
	client.statuses = map[string]int{"/api/v1/system/node_api/modules/m2": 404}
	delete(client.responses, "/api/v1/system/node_api/modules/m2")
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m2")); err != nil {
		t.Fatalf("RemoveAll m2 manifest cache: %v", err)
	}
	client.responses["/api/v1/system/node_api/modules"] = listWithM3
	client.responses["/api/v1/system/node_api/modules/m3"] = m3Body
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	stampBefore := attachStampOf(t, statePath, "m1")
	pre := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2 (render skipped): %v", err)
	}

	skipped := runner.Invocations[pre:]
	if hasSystemctlOp(skipped, "start", m3Unit) || hasSystemctlOp(skipped, "restart", m3Unit) {
		t.Errorf("a render-skipped tick must not start new module m3's units against users that were never rendered: %v", skipped)
	}
	if hasSystemctlOp(skipped, "start", m1WorkerUnit) || hasSystemctlOp(skipped, "restart", m1WorkerUnit) {
		t.Errorf("a render-skipped tick must not start a unit a manifest-only edit introduced: %v", skipped)
	}
	if _, ok := attachedDigest(t, statePath, "m3"); ok {
		t.Error("a render-skipped tick must not record m3 as attached")
	}
	if got := attachStampOf(t, statePath, "m1"); got != stampBefore {
		t.Errorf("a render-skipped tick must not stamp m1's reattach: stamp %q -> %q", stampBefore, got)
	}

	// Tick 3: m2 resolves again => the render runs, and BOTH pending changes
	// are picked up (nothing was stamped, so nothing was lost).
	delete(client.statuses, "/api/v1/system/node_api/modules/m2")
	client.responses["/api/v1/system/node_api/modules/m2"] = m2Body
	pre = len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 3 (render resolves): %v", err)
	}
	trusted := runner.Invocations[pre:]
	if !hasSystemctlOp(trusted, "start", m3Unit) {
		t.Errorf("the next trusted tick must attach m3 and start %s: %v", m3Unit, trusted)
	}
	if !hasSystemctlOp(trusted, "start", m1WorkerUnit) {
		t.Errorf("the next trusted tick must reattach m1 and start %s: %v", m1WorkerUnit, trusted)
	}
}

func attachStampOf(t *testing.T, statePath, moduleID string) string {
	t.Helper()
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	return st.LastAttachedManifestHashes[moduleID]
}
