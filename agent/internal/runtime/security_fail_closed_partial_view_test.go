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

// J3 (review round 5 REPLACEMENT review): publishSecurityFailClosed used to
// be a bare full-replace keyed on securityFailClosedPending alone — the
// units THIS pass actually decided. A module this pass could not even
// REACH the security-policy decision for (a manifest fetch failure, a
// no-digest module, a blob pull failure ahead of the drop-in step) never
// entered that set, so its PREVIOUSLY published refusal silently dropped out
// of SecurityFailClosedUnits() — reading as "recovered" to
// SecurityFailClosedSensor for a module whose confinement status this pass
// learned NOTHING new about. The alarm then re-raised on the next tick that
// could reach the module again: a flap with no underlying change.
//
// This test drives exactly the review's requested scenario: refused on tick
// 1, the module's manifest fetch fails outright on tick 2 (a partial view —
// same 502-mid-restart shape as partial_manifest_guard_test.go), and the
// refusal must still be reported; tick 3's fetch succeeds and the drop-in
// write now succeeds too, and ONLY THEN does it clear.
func TestSecurityFailClosed_SurvivesAPartialViewTickThatCannotReachTheModule(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	okResponse := versionBumpFixture("abc123")
	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": okResponse,
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
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}

	unit := lifecycle.UnitName("m1", "app")

	// TICK 1: force the drop-in write to fail — the module refuses.
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

	// TICK 2: PARTIAL VIEW — this module's manifest fetch fails outright
	// (502, same shape IMP-2dfbd7f62441 / the 2026-09-22 ops-hub outage
	// exercises elsewhere). RunOnce never reaches attachModule for m1 at all
	// this tick — the security-policy decision was NOT attempted.
	//
	// ManifestTTL is 0 (never stale) on this Reconciler, so LoadOrFetch would
	// otherwise serve tick 1's cached manifest straight off disk and never
	// even attempt the network call this test means to fail — evict the
	// on-disk cache first, exactly as bumpModuleDigest does for the same
	// reason in version_bump_detach_test.go.
	if err := os.RemoveAll(filepath.Join(tmpRoot, "manifests", "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = `{"success":false,"error":"boom"}`
	client.statuses = map[string]int{"/api/v1/system/node_api/modules/m1": 502}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	if got := r.SecurityFailClosedUnits(); !containsArg(got, unit) {
		t.Errorf("J3 REGRESSION: tick 2 (a partial-view tick that could not even reach %s) must still report the CARRIED-FORWARD refusal, got %v", unit, got)
	}

	// TICK 3: the fetch succeeds again AND the drop-in write now succeeds —
	// the module's decision is genuinely reached and clean; only now may it
	// clear.
	client.responses["/api/v1/system/node_api/modules/m1"] = okResponse
	client.statuses = nil
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3: %v", err)
	}
	if got := r.SecurityFailClosedUnits(); len(got) != 0 {
		t.Errorf("tick 3: expected SecurityFailClosedUnits() to clear once the module's decision is actually reached and clean, got %v", got)
	}
}

// J4 mutant M3 (review round 5), applied to J3's merge rather than H1's
// (reverted, J2): the carry-forward in publishSecurityFailClosed must touch
// ONLY the units of modules this pass could not attempt — a mutant that
// dropped or duplicated a DIFFERENT module's published entry while merging
// would pass every single-module test in this file. Two modules: m1 refuses
// tick 1 and is unreachable (partial view) tick 2; m2 doesn't exist until
// tick 2, where it attaches cleanly. Both must be independently correct on
// tick 2 — m1's stale refusal preserved, m2 present with no refusal.
func TestSecurityFailClosed_PartialViewPreservesAnotherModulesPublishedRefusal(t *testing.T) {
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
			"/api/v1/system/node_api/modules/m1": versionBumpFixture("abc123"),
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
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}

	m1Unit := lifecycle.UnitName("m1", "app")
	m2Unit := lifecycle.UnitName("m2", "app")

	// TICK 1: only m1 exists, and its drop-in write fails.
	m1DropInDir := filepath.Join(dropIns, m1Unit+".d")
	m1Blocked := filepath.Join(m1DropInDir, "capabilities.conf")
	if err := os.MkdirAll(m1Blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}
	if got := r.SecurityFailClosedUnits(); !containsArg(got, m1Unit) {
		t.Fatalf("tick 1: expected %s in SecurityFailClosedUnits(), got %v", m1Unit, got)
	}

	// TICK 2: m1 becomes an unreachable partial view (fetch fails); m2 is
	// newly assigned and attaches CLEANLY.
	if err := os.RemoveAll(filepath.Join(tmpRoot, "manifests", "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules"] = `{
		"success": true,
		"data": {"modules": [
			{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true},
			{"id":"m2", "name":"other-mod", "priority":90, "effective_priority":90, "has_data_file":true}
		]}
	}`
	client.responses["/api/v1/system/node_api/modules/m1"] = `{"success":false,"error":"boom"}`
	client.statuses = map[string]int{"/api/v1/system/node_api/modules/m1": 502}
	client.responses["/api/v1/system/node_api/modules/m2"] = `{
		"success": true,
		"data": {
			"id":"m2", "name":"other-mod",
			"priority":90, "effective_priority":90,
			"digest":"def456",
			"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
			"services": [
				{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}
			]
		}
	}`

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}

	got := r.SecurityFailClosedUnits()
	if !containsArg(got, m1Unit) {
		t.Errorf("J4/M3 REGRESSION: m1's stale (partial-view) refusal must be preserved when merging in m2's own tick-2 result, got %v", got)
	}
	if containsArg(got, m2Unit) {
		t.Errorf("J4/M3 REGRESSION: m2 attached cleanly this tick and must NOT appear in SecurityFailClosedUnits(), got %v", got)
	}
	if len(got) != 1 {
		t.Errorf("expected exactly m1's unit published (no duplication), got %v", got)
	}
}
