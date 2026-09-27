package runtime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// TestConfinementRestart_HubModuleInDesiredSetOnEmptyStateBlocksRestart is
// round Z's Z5 (reviewer A, MEDIUM): hostsControlPlaneModule used to scan
// ONLY current.AttachedModules — on a node's very first pivot boot (state
// empty, nothing "attached" by this tick's own bookkeeping yet) a hub
// module about to be freshly attached this SAME tick was invisible to the
// gate, so it read as clear and the fresh-attach loop's own R1 restarted a
// pre-started unit belonging to an ENTIRELY DIFFERENT, ordinary module.
//
// Fixture: state.json does not exist at all (truly empty — forcePivotNative
// alone, no pre-seeded inert module). Two modules are assigned: m1
// (ordinary) and m2 (name "powernode-hub-backend", a pinned control-plane
// identity) — NEITHER is attached yet; both land in the fresh-attach loop
// on this first tick. m1's own unit file is pre-seeded on disk with the
// EXACT body the renderer would produce (simulating compose having already
// started it, X2's own established technique) and stubbed active, so the
// only remaining signal that can trigger a restart is m1's own (first-
// ever) confinement write — the SAME shape
// TestReconcile_FreshAttachRestartsAPreStartedUnitWithStaleConfinement
// uses, but with m2 (a hub module) ALSO present in the desired set this
// same tick.
func TestConfinementRestart_HubModuleInDesiredSetOnEmptyStateBlocksRestart(t *testing.T) {
	forcePivotNative(t)
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json") // no SaveState call: truly empty
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true},
					{"id":"m2", "name":"powernode-hub-backend", "priority":50, "effective_priority":50, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"app-mod", "digest":"abc123",
				         "priority":100, "effective_priority":100,
				         "services": [{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}]}
			}`,
			"/api/v1/system/node_api/modules/m2": `{
				"success": true,
				"data": {"id":"m2", "name":"powernode-hub-backend", "digest":"def456",
				         "priority":50, "effective_priority":50,
				         "services": [{"name":"svc", "start_command":"/bin/true", "restart_policy":"always"}]}
			}`,
		},
	}

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
		PlatformURL:    "https://ops-hub.example.test",
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.22"}}, []string{"192.0.2.99"}, nil)

	unit := lifecycle.UnitName("m1", "app")
	svc := manifest.Service{Name: "app", StartCommand: "/bin/true", RestartPolicy: "always"}
	body := lifecycle.RenderUnitModeGraph(svc, "m1", lifecycle.RootModeNative, nil)
	if err := os.MkdirAll(lifecycle.UnitDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(lifecycle.UnitPath("m1", "app"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if hasSystemctlOp(runner.Invocations, "restart", unit) {
		t.Errorf("Z5 REGRESSION: expected m1's restart to be blocked because m2 (a hub module) is in the DESIRED set on this empty-state tick, invocations=%v", runner.Invocations)
	}
}
