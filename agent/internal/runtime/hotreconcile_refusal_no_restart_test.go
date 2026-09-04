package runtime

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// ORDERING. attachModule started the module's units BEFORE anything
// materialized its files, so a refused or partial materialization left systemd
// running the new unit definitions against the OLD (or half-written) tree.
//
// The pre-flight (escalateIfHotRungTooSmall) fixed the RATCHET — a module that
// cannot fit no longer burns the scratch discovering it. It did not fix this:
// a clean pre-flight refusal still arrived after AttachServicesMode had already
// written the unit files, run daemon-reload and started the services. The
// module is then running its new units over content that was never written.
//
// reconcile.go's own comment on the mid-walk arm concedes the same thing for
// the TOCTOU case: the module "sits at an arbitrary alphabetical boundary with
// its units already restarted against a mixture of old and new files".
//
// Live, ops-hub deploy 4 on 2026-09-04: hub-frontend v29 served the Sep 3
// index.html over new assets (400 asset files merged, 499 in the image), and
// the v92/v93 backend strand is the same defect on a module that does have
// units. One root cause, two symptoms.
//
// The invariant these tests pin: a refused materialization starts NOTHING. The
// old content keeps being served by the units that are already running, which
// is a state the node was already in and can survive until a later tick or the
// soft-recompose rung applies the update properly.

// constantFree pins the free-space probe so the PRE-FLIGHT verdict is
// deterministic and does not depend on what else the harness wrote under the
// temp root. Both the plan and the per-file guard read the same number, so a
// refusal here is unambiguously the pre-flight's — nothing is written, and the
// assertion below cannot be satisfied by an abort that happened to write zero
// bytes for some other reason.
func constantFree(t *testing.T, free uint64) {
	t.Helper()
	orig := freeBytesAt
	freeBytesAt = func(string) (uint64, error) { return free, nil }
	t.Cleanup(func() { freeBytesAt = orig })
}

// refusalFixture builds the second-tick re-attach scenario from
// TestReconcilerRunOnceReattachesOnManifestChange: m1 is already attached with
// a stale services hash, so the manifest now carrying a service re-attaches it
// and reaches the hot-materialization path with stateWasEmpty=false.
//
// Returns the recorder so a caller can ask whether systemd was touched.
func refusalFixture(t *testing.T) (*Reconciler, mount.Layout, *mount.RecorderRunner, string) {
	t.Helper()
	forcePivotNative(t)
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	staleHash := (&manifest.Manifest{Services: []manifest.Service{}}).ServicesHash()
	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m1", Digest: "abc123", Priority: 100},
		},
		LastAttachedManifestHashes: map[string]string{"m1": staleHash},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"qga", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"qga", "digest":"abc123",
				         "priority":100, "effective_priority":100,
				         "services": [{"name":"qga", "start_command":"/usr/sbin/qemu-ga", "restart_policy":"always"}]}
			}`,
		},
	}

	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	runner := &mount.RecorderRunner{}

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:       client,
		ManifestClient:      client,
		ManifestRoot:        filepath.Join(tmpRoot, "manifests"),
		Puller:              &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:            verify.AlwaysOK{},
		MountRunner:         runner,
		Layout:              layout,
		StatePath:           statePath,
		ScratchMinFreeBytes: preflightFloor,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	return r, layout, runner, statePath
}

func containsID(ids []string, want string) bool {
	for _, id := range ids {
		if id == want {
			return true
		}
	}
	return false
}

// unitStarted reports whether systemd was asked to start the module's unit.
// `systemctl start <unit>` is the last step of AttachServicesMode, so its
// absence is the direct oracle for "the refresh was refused without restarting
// anything".
func unitStarted(rec *mount.RecorderRunner, unit string) bool {
	for _, inv := range rec.Invocations {
		if inv.Name != "systemctl" || inv.Op != "Run" {
			continue
		}
		for i, a := range inv.Args {
			if a == "start" && i+1 < len(inv.Args) && inv.Args[i+1] == unit {
				return true
			}
		}
	}
	return false
}

// A module whose diff cannot fit the hot rung must not have its units started.
// Starting them is what converts "this update did not apply" into "this update
// applied wrong": systemd runs the new unit definitions against a tree that
// still holds the previous version's files.
func TestRunOnce_RefusedMaterializationDoesNotStartUnits(t *testing.T) {
	r, layout, runner, statePath := refusalFixture(t)
	oversizeModulePayload(t, layout.ModuleMountPath("abc123"))
	// 800 KB of payload against a 500 KB floor with 600 KB free: the whole
	// diff cannot fit, so the pre-flight refuses before writing a byte.
	constantFree(t, 600_000)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if unitStarted(runner, "powernode-m1-qga.service") {
		t.Fatalf("a module whose materialization was REFUSED had its unit started; " +
			"systemd is now running the new unit definition against the old files, " +
			"which is the deploy-4 shape (invocations above)")
	}

	// The refusal must still be recorded, or the next tick believes this
	// manifest is materialized and the heartbeat claims the new version runs.
	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if _, stamped := state.LastAttachedManifestHashes["m1"]; stamped {
		t.Fatalf("refused module kept its manifest-hash stamp; the reattach gate will " +
			"skip it next tick and it never converges")
	}
	if !containsID(state.UnmaterializedModules, "m1") {
		t.Fatalf("refused module not recorded as unmaterialized (got %v); the heartbeat "+
			"resumes claiming the unwritten version is running", state.UnmaterializedModules)
	}
}

// CONTROL. The refusal path must not become a blanket refusal to start units:
// a module whose diff fits is materialized AND started, exactly as before.
func TestRunOnce_FittingModuleStillStartsUnits(t *testing.T) {
	r, layout, runner, statePath := refusalFixture(t)
	oversizeModulePayload(t, layout.ModuleMountPath("abc123"))
	// 5 MB free against a 500 KB floor leaves 4.5 MB usable for an 800 KB diff.
	constantFree(t, 5_000_000)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if !unitStarted(runner, "powernode-m1-qga.service") {
		t.Fatalf("a module that fits did not have its unit started; the ordering fix "+
			"must not suppress the normal attach (invocations: %v)", runner.Invocations)
	}

	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if containsID(state.UnmaterializedModules, "m1") {
		t.Fatalf("a module that fits was recorded as unmaterialized")
	}
}

// firstAttachRefusalFixture is refusalFixture's sibling for the OTHER arm.
//
// refusalFixture exercises the re-attach loop only: its module is pre-seeded
// into AttachedModules, so mount.Reconcile never returns it in toAttach. The
// toAttach loop has its own materialization gate and its own `continue`, and a
// mutation that deleted that `continue` survived the whole package suite —
// which is exactly what an untested arm looks like.
//
// The shape needed is "state is not empty, but THIS module is new": m0 is
// already attached with a matching digest and a matching services hash, so it
// is inert (neither toAttach nor toReattach) and only serves to make
// stateWasEmpty false. m1 is genuinely new, so it lands in toAttach.
func firstAttachRefusalFixture(t *testing.T) (*Reconciler, mount.Layout, *mount.RecorderRunner, string) {
	t.Helper()
	forcePivotNative(t)
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	inertHash := (&manifest.Manifest{Services: []manifest.Service{}}).ServicesHash()
	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m0", Digest: "deadbeef", Priority: 50},
		},
		LastAttachedManifestHashes: map[string]string{"m0": inertHash},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m0", "name":"inert", "priority":50, "effective_priority":50, "has_data_file":true},
					{"id":"m1", "name":"qga", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m0": `{
				"success": true,
				"data": {"id":"m0", "name":"inert", "digest":"deadbeef",
				         "priority":50, "effective_priority":50, "services": []}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"qga", "digest":"abc123",
				         "priority":100, "effective_priority":100,
				         "services": [{"name":"qga", "start_command":"/usr/sbin/qemu-ga", "restart_policy":"always"}]}
			}`,
		},
	}

	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	runner := &mount.RecorderRunner{}

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:       client,
		ManifestClient:      client,
		ManifestRoot:        filepath.Join(tmpRoot, "manifests"),
		Puller:              &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:            verify.AlwaysOK{},
		MountRunner:         runner,
		Layout:              layout,
		StatePath:           statePath,
		ScratchMinFreeBytes: preflightFloor,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	return r, layout, runner, statePath
}

// The toAttach arm of the same invariant. A module arriving for the FIRST time
// on a node that is already up (so stateWasEmpty is false) must not have its
// units started when its materialization is refused — a brand-new module whose
// files were never written has NOTHING on disk to run, so starting it is
// strictly worse than the re-attach case.
func TestRunOnce_RefusedMaterializationOnFirstAttachDoesNotStartUnits(t *testing.T) {
	r, layout, runner, statePath := firstAttachRefusalFixture(t)
	oversizeModulePayload(t, layout.ModuleMountPath("abc123"))
	constantFree(t, 600_000)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if unitStarted(runner, "powernode-m1-qga.service") {
		t.Fatalf("a NEWLY-ATTACHED module whose materialization was refused had its " +
			"unit started; nothing of it is on disk at all")
	}

	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if !containsID(state.UnmaterializedModules, "m1") {
		t.Fatalf("refused first-attach module not recorded as unmaterialized (got %v)",
			state.UnmaterializedModules)
	}
}

// CONTROL for the toAttach arm, mirroring the re-attach control: a new module
// that fits is materialized AND started.
func TestRunOnce_FittingFirstAttachStartsUnits(t *testing.T) {
	r, layout, runner, _ := firstAttachRefusalFixture(t)
	oversizeModulePayload(t, layout.ModuleMountPath("abc123"))
	constantFree(t, 5_000_000)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if !unitStarted(runner, "powernode-m1-qga.service") {
		t.Fatalf("a new module that fits did not have its unit started (invocations: %v)",
			runner.Invocations)
	}
}

// AttachOne is the `powernode-agent attach <id>` CLI path — a THIRD caller of
// attachModule, outside both reconcile loops. Splitting the service start out
// of attachModule silently stripped its units: it returned attach_status
// "attached" with no unit ever written, against a CLI that documents
// "mount + start units". Nothing covered it, so nothing caught it.
//
// AttachOne never materializes (no hotReconcileIfNeeded call), so unlike the
// loops its service start is unconditional.
func TestAttachOne_StartsUnits(t *testing.T) {
	r, _, runner, _ := firstAttachRefusalFixture(t)

	status, err := r.AttachOne(context.Background(), "m1")
	if err != nil {
		t.Fatalf("AttachOne: %v", err)
	}
	if status != "attached" {
		t.Fatalf("AttachOne status = %q, want \"attached\"", status)
	}
	if !unitStarted(runner, "powernode-m1-qga.service") {
		t.Fatalf("AttachOne reported %q but never started the unit — a false success "+
			"(invocations: %v)", status, runner.Invocations)
	}
}
