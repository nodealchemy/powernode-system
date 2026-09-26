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

// K4 (review round 6): J3's carry-forward ("a unit whose module this pass
// could not attempt is republished from the previous pass") was UNBOUNDED —
// it never asked whether the module was still assigned at all. A module
// that is GENUINELY UNASSIGNED (removed from the platform's module list
// entirely, a clean fetch that simply excludes it — never a fetch failure)
// can NEVER become "attempted" again, because RunOnce no longer iterates it
// at all; under the old rule its last-known refusal would republish FOREVER,
// a permanent stale alarm with no tick that could ever clear it.
// publishSecurityFailClosed now bounds carry-forward to units belonging to a
// module the CURRENT tick still finds in desired/manifestFetchFailed/
// retained — this test proves a genuinely unassigned module's fail-closed
// unit drops on the very next tick, not never.
func TestSecurityFailClosed_UnassignedModuleStopsBeingPublished(t *testing.T) {
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

	// TICK 1: force the drop-in write to fail — m1 fails closed.
	unitDropInDir := filepath.Join(dropIns, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}
	if got := r.SecurityFailClosedUnits(); !containsArg(got, unit) {
		t.Fatalf("tick 1: expected %s in SecurityFailClosedUnits(), got %v", unit, got)
	}

	// TICK 2: m1 is UNASSIGNED entirely — a clean fetch of the modules list
	// that simply no longer names it (not a fetch failure, not a manifest
	// error: the platform genuinely no longer assigns this node the module).
	client.responses["/api/v1/system/node_api/modules"] = `{
		"success": true,
		"data": {"modules": []}
	}`

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	if got := r.SecurityFailClosedUnits(); containsArg(got, unit) {
		t.Errorf("K4 REGRESSION: tick 2 (m1 genuinely unassigned) must stop publishing %s — a permanently unreachable module can never clear otherwise, got %v", unit, got)
	}
}
