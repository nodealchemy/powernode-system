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

// Round Z, Z2 (IMP-caef5c00d63f): restartPermitted's own POSITIVE PROOF
// requirement — resolver-only evidence (selfHostState()==No) is not enough;
// none of this node's attached modules may resolve to a pinned
// control-plane name either, fail-safe on an unresolved one.

// pinnedHubModuleNames is round Z's Z9 fix: the Z8 tests below originally
// iterated `for name := range hubModuleNames` — the very map under test —
// so a name DELETED from that map dropped out of the test's own coverage
// along with it, and both subtests for that name simply stopped running
// rather than failing. Reviewer A confirmed this by deleting
// powernode-hub-worker and powernode-extension-system from selfhost.go and
// finding both deletions went undetected. This is a hard-coded, literal
// copy of the three pinned names — independent of hubModuleNames — so a
// name missing from the map is a test FAILURE, not a test that quietly
// never ran.
var pinnedHubModuleNames = []string{
	"powernode-hub-backend",
	"powernode-hub-worker",
	"powernode-extension-system",
}

// TestHostsControlPlaneModule_HubModuleNameMatches is the direct unit test
// for the pin itself: a module named exactly like one of the pinned
// control-plane identities is a positive match.
//
// Round Z, Z8 (reviewer A): the original version of this test only ever
// supplied "powernode-hub-backend" — a mutant that special-cased the
// -backend name (e.g. hardcoding the comparison instead of reading
// hubModuleNames, or dropping one of the other two map entries) would
// survive, since nothing exercised powernode-hub-worker or
// powernode-extension-system at all. Table-driven over all three pinned
// names closes that gap. Round Z, Z9: iterates the hard-coded
// pinnedHubModuleNames list, not hubModuleNames itself — see its doc.
func TestHostsControlPlaneModule_HubModuleNameMatches(t *testing.T) {
	for _, name := range pinnedHubModuleNames {
		t.Run(name, func(t *testing.T) {
			attached := []mount.Module{{ID: "m1"}}
			manifests := map[string]*manifest.Manifest{"m1": {ID: "m1", Name: name}}
			if !hostsControlPlaneModule(attached, manifests) {
				t.Errorf("Z8 REGRESSION: expected a module named %s to be recognised as control-plane", name)
			}
		})
	}
}

// TestHostsControlPlaneModule_UnnamedModuleFailsSafe is the second named
// Z2 test: a module whose manifest carries no Name at all (or whose
// manifest this tick could not be resolved) must count AS control-plane —
// positive proof, not absence of evidence.
func TestHostsControlPlaneModule_UnnamedModuleFailsSafe(t *testing.T) {
	attached := []mount.Module{{ID: "m1"}}

	t.Run("empty Name", func(t *testing.T) {
		manifests := map[string]*manifest.Manifest{"m1": {ID: "m1", Name: ""}}
		if !hostsControlPlaneModule(attached, manifests) {
			t.Error("Z2 REGRESSION: an unnamed module must fail safe as control-plane")
		}
	})
	t.Run("manifest missing entirely", func(t *testing.T) {
		manifests := map[string]*manifest.Manifest{}
		if !hostsControlPlaneModule(attached, manifests) {
			t.Error("Z2 REGRESSION: a module this tick could not resolve a manifest for must fail safe as control-plane")
		}
	})
}

// TestHostsControlPlaneModule_OrdinaryNamedModuleIsNotControlPlane is the
// control: a module with a resolved, non-hub name is genuinely NOT
// control-plane — the fail-safe must not swallow the ordinary case too.
func TestHostsControlPlaneModule_OrdinaryNamedModuleIsNotControlPlane(t *testing.T) {
	attached := []mount.Module{{ID: "m1"}}
	manifests := map[string]*manifest.Manifest{"m1": {ID: "m1", Name: "app-mod"}}
	if hostsControlPlaneModule(attached, manifests) {
		t.Error("an ordinary, positively-named non-hub module must not read as control-plane")
	}
}

// TestRestartPermitted_HubModuleAttachedRefusesEvenOnDefiniteNo is the
// first named Z2 test: selfHostState() resolving to a definite No is not
// sufficient on its own — a positively-identified hub module attached
// anywhere on this node still refuses every restart.
func TestRestartPermitted_HubModuleAttachedRefusesEvenOnDefiniteNo(t *testing.T) {
	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.22"}}, []string{"192.0.2.99"}, nil)
	r := selfHostReconciler(t, "https://ops-hub.example.test")
	if r.selfHostState() != selfHostNo {
		t.Fatalf("precondition: expected selfHostState()==No, got %v", r.selfHostState())
	}

	r.hostsControlPlaneModule = true
	if r.restartPermitted() {
		t.Error("Z2 REGRESSION: expected restartPermitted() to refuse despite a definite No, because a hub module is attached")
	}

	r.hostsControlPlaneModule = false
	if !r.restartPermitted() {
		t.Error("precondition check: restartPermitted() should be true once the hub-module signal clears, given a definite No")
	}
}

// hubGateReconciler builds a two-module reconciler: m1 (ordinary) and m2,
// whose name is set by the caller — used to prove that hosting a hub module
// ANYWHERE on the node (not just as the module whose OWN confinement is
// changing) blocks R1 for every module, end to end through RunOnce.
func hubGateReconciler(t *testing.T, m2Name string) (r *Reconciler, client *stubModulesClient, runner *mount.RecorderRunner, manifestRoot string) {
	t.Helper()
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	manifestRoot = filepath.Join(tmpRoot, "manifests")
	t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client = &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{
			"success": true,
			"data": {"modules": [
				{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true},
				{"id":"m2", "name":"` + m2Name + `", "priority":50, "effective_priority":50, "has_data_file":true}
			]}
		}`,
		"/api/v1/system/node_api/modules/m1": manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN"}),
		"/api/v1/system/node_api/modules/m2": `{
			"success": true,
			"data": {
				"id":"m2", "name":"` + m2Name + `",
				"priority":50, "effective_priority":50,
				"digest":"def456",
				"services": [{"name":"svc", "start_command":"/bin/true", "restart_policy":"always"}]
			}
		}`,
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
	r.cfg.PlatformURL = "https://ops-hub.example.test"
	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.22"}}, []string{"192.0.2.99"}, nil)
	return r, client, runner, manifestRoot
}

// TestConfinementRestart_HubModuleAttachedAnywhereBlocksEveryRestart is Z2's
// first named test, driven end to end through RunOnce (not just the direct
// field manipulation above): m2 is a pinned hub module; m1 is an ordinary
// module whose OWN confinement changes. Even though m1 itself is not the
// hub module, hosting m2 anywhere on this node must block m1's restart too.
//
// Round Z, Z8 (reviewer A): subtests over all three pinned names — the
// original version only ever ran m2 as "powernode-hub-backend", so a
// mutant narrowing the end-to-end gate to that one name specifically
// (rather than reading hubModuleNames generically) would survive. Round Z,
// Z9: iterates the hard-coded pinnedHubModuleNames list, not hubModuleNames
// itself — see its doc.
func TestConfinementRestart_HubModuleAttachedAnywhereBlocksEveryRestart(t *testing.T) {
	for _, name := range pinnedHubModuleNames {
		name := name
		t.Run(name, func(t *testing.T) {
			r, client, runner, manifestRoot := hubGateReconciler(t, name)
			unit := lifecycle.UnitName("m1", "app")

			if err := r.RunOnce(context.Background()); err != nil {
				t.Fatalf("RunOnce tick 1: %v", err)
			}

			if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
				t.Fatal(err)
			}
			client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
			runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
			pre := len(runner.Invocations)

			if err := r.RunOnce(context.Background()); err != nil {
				t.Fatalf("RunOnce tick 2: %v", err)
			}
			tick2 := runner.Invocations[pre:]
			if hasSystemctlOp(tick2, "restart", unit) {
				t.Errorf("Z2/Z8 REGRESSION: expected m1's restart to be refused because m2 (%s, a pinned hub module) is attached, invocations=%v", name, tick2)
			}
		})
	}
}

// TestConfinementRestart_OrdinaryNodeWithNoHubModulesStillRestarts is Z2's
// third named test: the SAME two-module shape, but m2 is an ordinary
// (non-hub) module — R1 must still fire normally.
func TestConfinementRestart_OrdinaryNodeWithNoHubModulesStillRestarts(t *testing.T) {
	r, client, runner, manifestRoot := hubGateReconciler(t, "another-ordinary-module")
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}

	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	pre := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	tick2 := runner.Invocations[pre:]
	if !hasSystemctlOp(tick2, "restart", unit) {
		t.Errorf("expected m1's restart to fire normally on an ordinary node with no hub modules, invocations=%v", tick2)
	}
}
