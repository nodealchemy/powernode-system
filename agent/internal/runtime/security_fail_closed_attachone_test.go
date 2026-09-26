package runtime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// H1 (review round 5, HIGH): AttachOne (the `powernode-agent attach <id>` CLI
// hot-add path) calls attachModule but, before this fix, never bracketed it
// with a reset/publish cycle — so a fail-closed refusal it produced
// accumulated into securityFailClosedPending and sat there, invisible to
// SecurityFailClosedUnits()/buildHeartbeat/SecurityFailClosedSensor, until
// some LATER RunOnce pass happened to touch the same module and publish over
// it. Every direct attachModule caller is audited in this package: RunOnce
// (two loops, already covered) and AttachOne (this file). DetachOne never
// calls attachModule at all.

func attachOneFixtureReconciler(t *testing.T, tmpRoot, statePath string, client *stubModulesClient, runner *mount.RecorderRunner) *Reconciler {
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

func narrowCapModuleResponse(digest string) string {
	return `{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"` + digest + `",
			"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
			"services": [
				{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}
			]
		}
	}`
}

func TestAttachOne_FailClosedRefusalVisibleOnSecurityFailClosedUnits(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules/m1": narrowCapModuleResponse("abc123"),
	}}
	runner := &mount.RecorderRunner{}
	r := attachOneFixtureReconciler(t, tmpRoot, statePath, client, runner)

	unit := lifecycle.UnitName("m1", "app")
	unitDropInDir := filepath.Join(dropIns, unit+".d")
	if err := os.MkdirAll(unitDropInDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(unitDropInDir, "capabilities.conf"), 0o755); err != nil {
		t.Fatal(err)
	}

	if _, err := r.AttachOne(context.Background(), "m1"); err == nil {
		t.Fatal("AttachOne must return an error when the security drop-in fails to write (fail closed)")
	}

	if got := r.SecurityFailClosedUnits(); !containsArg(got, unit) {
		t.Errorf("H1 REGRESSION: AttachOne's fail-closed refusal never reached SecurityFailClosedUnits(), got %v", got)
	}
}

// The other half of H1: a unit that RECOVERED once (a prior successful
// attach marked it in SecurityFailClosedRecovered, which G5 uses to suppress
// a STALE boot-time pivot entry) must still show as a CURRENT failure via
// SecurityFailClosedUnits() if AttachOne later fails on it again — recovered
// is a historical fact about the past, not a standing exemption from a new
// failure.
func TestAttachOne_PreviouslyRecoveredUnitFailingAgainIsVisible(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules/m1": narrowCapModuleResponse("abc123"),
	}}
	runner := &mount.RecorderRunner{}
	r := attachOneFixtureReconciler(t, tmpRoot, statePath, client, runner)

	unit := lifecycle.UnitName("m1", "app")

	// Step 1: a SUCCESSFUL attach, direct through attachModule (not
	// AttachOne, so state.json's AttachedModules stays empty and the
	// upcoming AttachOne call below does not short-circuit on
	// "already_attached") — marks the unit RECOVERED (G5).
	mf := &manifest.Manifest{
		ID:                          "m1",
		Name:                        "app-mod",
		Digest:                      "abc123",
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"capabilities": []any{"CAP_CHOWN"}, "user_namespace": false}},
		Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	if err := r.attachModule(context.Background(), mount.Module{ID: "m1", Digest: "abc123", Priority: 1}, mf); err != nil {
		t.Fatalf("test setup: attachModule (first, successful) must succeed: %v", err)
	}
	if recovered := r.SecurityFailClosedRecovered(); !recovered[unit] {
		t.Fatalf("test setup: expected %s marked recovered after the first successful attach, got %v", unit, recovered)
	}

	// Step 2: force the drop-in write to fail, then attach again through
	// AttachOne (a fresh digest so it does not read as "already_attached" —
	// AttachOne's own state.json bookkeeping was never touched by step 1).
	unitDropInDir := filepath.Join(dropIns, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	// The first (successful) attach already wrote capabilities.conf as a
	// regular FILE — remove it before turning the same path into a
	// directory, or MkdirAll fails with "not a directory".
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = narrowCapModuleResponse("def456")

	if _, err := r.AttachOne(context.Background(), "m1"); err == nil {
		t.Fatal("AttachOne must fail closed on the second attempt")
	}

	if recovered := r.SecurityFailClosedRecovered(); !recovered[unit] {
		t.Fatalf("recovered marker must still be set (it is a historical fact, not cleared by a later failure), got %v", recovered)
	}
	if got := r.SecurityFailClosedUnits(); !containsArg(got, unit) {
		t.Errorf("H1/G5 REGRESSION: a unit marked recovered must still show as a CURRENT failure when it fails again, got %v", got)
	}
}
