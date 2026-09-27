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

// W1 (IMP-caef5c00d63f round W, HIGH): a live reconcile that changes ONLY a
// module's security policy (SAME digest — a manifest-only capabilities-list
// edit, exactly TestSecurityFailClosed_ReattachPathRefusalReachesSecurityFailClosedUnits'
// own fixture shape, which drives m1 into RunOnce's toReattach loop, not
// toAttach) previously did NO daemon-reload and NO restart at all: the
// drop-in write happens in attachModule/applyModuleSecurityPolicy, entirely
// invisible to AttachServicesModeOpts' own anyWritten/RestartChanged
// tracking (unit-BODY writes only). The reattach was still stamped
// converged. These two tests are the "before" of the "before/after" this
// round's own W1 fix must invert: a non-self-hosted node must actually
// RESTART the unit so the new confinement takes effect; a self-hosted node
// must reload without restarting and must NOT be stamped converged.
func newConfinementReattachReconciler(t *testing.T) (r *Reconciler, client *stubModulesClient, runner *mount.RecorderRunner, statePath, manifestRoot, dropIns string) {
	t.Helper()
	tmpRoot := t.TempDir()
	statePath = filepath.Join(tmpRoot, "state.json")
	manifestRoot = filepath.Join(tmpRoot, "manifests")
	dropIns = t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client = &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{
			"success": true,
			"data": {"modules": [
				{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}
			]}
		}`,
		"/api/v1/system/node_api/modules/m1": manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN"}),
	}}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	runner = &mount.RecorderRunner{}
	var err error
	r, err = NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	return r, client, runner, statePath, manifestRoot, dropIns
}

func TestReconcile_ConfinementOnlyChangeRestartsActiveUnitOnLiveReattach(t *testing.T) {
	r, client, runner, _, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	// TICK 1: clean attach.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}

	// TICK 2: SAME digest, capabilities list changes (attachStamp moves,
	// m1 goes into toReattach). The unit is ACTIVE and its BODY does not
	// change at all (services: block is identical) — only the drop-in does.
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	preInvocations := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}

	tick2 := runner.Invocations[preInvocations:]
	if !hasSystemctlOp(tick2, "restart", unit) {
		t.Errorf("W1 REGRESSION: a confinement-only change (capabilities list, no body change) on an ACTIVE unit must be restarted on a non-self-hosted node, got invocations=%v", tick2)
	}
}

func TestReconcile_ConfinementOnlyChangeSelfHostedStaysUnconvergedAndPending(t *testing.T) {
	r, client, runner, statePath, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}
	r.selfHostLatched = true

	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	onErrors = nil
	preInvocations := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (self-hosted): %v", err)
	}

	tick2 := runner.Invocations[preInvocations:]
	if hasSystemctlOp(tick2, "restart", unit) {
		t.Errorf("W1 REGRESSION (rule 1): a self-hosted node must NEVER restart on a confinement-only change, got invocations=%v", tick2)
	}
	if !convergenceFailuresContain(onErrors, "reconciler:confinement_pending_restart") || !convergenceFailuresContain(onErrors, unit) {
		t.Errorf("W1 REGRESSION: expected reconciler:confinement_pending_restart naming %s, got onErrors=%v", unit, onErrors)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	// The stamp already written earlier in this SAME tick (before
	// attachModuleServices ran) must have been UNDONE — a self-hosted
	// confinement-pending-restart module is NOT converged, so it must stay
	// queued for a retry on the very next tick.
	if _, stamped := st.LastAttachedManifestHashes["m1"]; stamped {
		t.Errorf("W1 REGRESSION: expected m1's attach stamp to be cleared while a confinement restart is pending — got %q", st.LastAttachedManifestHashes["m1"])
	}
}
