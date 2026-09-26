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

// G2 (review round 5, both reviewers proved by mutation nothing tests this):
// a module refused for a security drop-in write failure on ONE RunOnce pass
// must attach and start normally on a LATER pass once the write succeeds, and
// Reconciler.SecurityFailClosedUnits() must clear — it describes the pass
// that just ran, never an older one. Fails if resetSecurityFailClosed()
// (reconcile.go, top of RunOnce) is removed: without it, pass 1's failure
// would stay published forever even after pass 2 recovers.
func TestReconcilerRunOnce_RecoversAfterASecurityDropInWriteFailure(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {
					"id":"m1", "name":"app-mod",
					"priority":100, "effective_priority":100,
					"digest":"abc123",
					"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
					"services": [
						{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}
					]
				}
			}`,
		},
	}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}

	unit := lifecycle.UnitName("m1", "app")
	unitDropInDir := filepath.Join(dropIns, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	if err := os.MkdirAll(unitDropInDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// PASS 1: capabilities.conf is a pre-existing DIRECTORY -> the write fails.
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}

	startInvocation := func() (int, bool) {
		for i, inv := range runner.Invocations {
			if inv.Name == "systemctl" && inv.Op == "Run" &&
				len(inv.Args) >= 2 && inv.Args[0] == "start" && inv.Args[1] == unit {
				return i, true
			}
		}
		return -1, false
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	if got := r.SecurityFailClosedUnits(); !containsArg(got, unit) {
		t.Fatalf("pass 1: expected %s in SecurityFailClosedUnits(), got %v", unit, got)
	}
	if _, started := startInvocation(); started {
		t.Fatalf("pass 1: unit must NOT have been started while its security drop-in failed to write")
	}

	// Unblock: capabilities.conf can now write normally.
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	if got := r.SecurityFailClosedUnits(); len(got) != 0 {
		t.Errorf("pass 2: SecurityFailClosedUnits() must clear once the write succeeds, got %v", got)
	}
	if _, started := startInvocation(); !started {
		t.Errorf("pass 2: expected `systemctl start %s` now that the drop-in write succeeds, got invocations: %v", unit, runner.Invocations)
	}
}
