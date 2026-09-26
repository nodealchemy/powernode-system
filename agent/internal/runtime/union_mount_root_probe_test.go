package runtime

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// pinRootModeChecked forces pivotAwareRootModeChecked to a fixed result for
// the test's duration.
func pinRootModeChecked(t *testing.T, mode lifecycle.RootMode, err error) {
	t.Helper()
	orig := pivotAwareRootModeChecked
	pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return mode, err }
	t.Cleanup(func() { pivotAwareRootModeChecked = orig })
}

func unionMountWasAttempted(run *mount.RecorderRunner) bool {
	for _, inv := range run.Invocations {
		if inv.Name != "mount" {
			continue
		}
		for _, a := range inv.Args {
			if a == "overlay" {
				return true
			}
		}
	}
	return false
}

// unionMountProbeFixture builds a Reconciler with one already-in-sync
// attached module (m1), so RunOnce reaches the union-mount block with
// nothing else to attach/detach/reattach — isolating the union-mount
// decision from the rest of the tick. seedUnionMounted seeds the PRIOR
// tick's current.UnionMounted, so a test can assert whether a declined
// union step preserves it.
func unionMountProbeFixture(t *testing.T, seedUnionMounted bool) (*Reconciler, *mount.RecorderRunner, *[]string, string) {
	t.Helper()
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")

	seedManifest := &manifest.Manifest{
		Services: []manifest.Service{
			{Name: "nginx", StartCommand: "/usr/sbin/nginx", RestartPolicy: "always"},
		},
	}
	mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{{ID: "m1", Digest: "abc123", Priority: 100}},
		LastAttachedManifestHashes: map[string]string{
			"m1": testAttachStamp("m1", seedManifest.Services),
		},
		UnionMounted: seedUnionMounted,
	})

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{
			"success": true,
			"data": {"modules": [
				{"id":"m1", "name":"nginx", "priority":100, "effective_priority":100, "has_data_file":true}
			]}
		}`,
		"/api/v1/system/node_api/modules/m1": `{
			"success": true,
			"data": {"id":"m1", "name":"nginx", "digest":"abc123",
			         "priority":100, "effective_priority":100,
			         "services": [{"name":"nginx", "start_command":"/usr/sbin/nginx", "restart_policy":"always"}]}
		}`,
	}}
	puller := &stubPuller{cacheDir: tmpRoot}
	runner := &mount.RecorderRunner{}
	var signals []string

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
		OnError:        func(stage string, err error) { signals = append(signals, stage) },
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	return r, runner, &signals, statePath
}

// TestRunOnce_UnionMount_FailsClosedOnRootModeProbeError is FAIL CLOSED
// (IMP-81aa3112), the same asymmetry already established for detachModule's
// unmountWouldStripLiveRoot: a statfs probe failure must not be read as
// "not native" here, because that reading takes the MUTATING else-branch
// below (mounting a second overlay). On a node that really is pivot-booted
// that creates the kernel-documented "upperdir/workdir is in-use as
// upperdir/workdir of another mount" undefined behavior the RootModeNative
// branch exists specifically to avoid. An uncertain probe must decline the
// union step entirely this tick, not guess chroot — current.UnionMounted is
// left at whatever it already was, never forced to either true or false.
func TestRunOnce_UnionMount_FailsClosedOnRootModeProbeError(t *testing.T) {
	pinRootModeChecked(t, lifecycle.RootModeChroot, errors.New("statfs boom"))
	r, runner, signals, statePath := unionMountProbeFixture(t, false)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if unionMountWasAttempted(runner) {
		t.Fatal("attempted a union mount despite an unresolved root-mode probe — this risks a double overlay over a live pivoted root")
	}
	found := false
	for _, s := range *signals {
		if s == "reconciler:root_mode_probe_failed" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected reconciler:root_mode_probe_failed, got %v", *signals)
	}

	state, lerr := mount.LoadState(statePath)
	if lerr != nil {
		t.Fatalf("LoadState: %v", lerr)
	}
	if state.UnionMounted {
		t.Error("UnionMounted must be left at its previous value (false) when the union step is declined, never forced true")
	}
}

// TestRunOnce_UnionMount_FailsClosedPreservesPriorUnionMountedTrue is the
// other half of the "left at whatever it already was" claim above: seeded
// true, a declined union step must not flip it to false either — a probe
// failure is not evidence the previously-mounted union went away.
func TestRunOnce_UnionMount_FailsClosedPreservesPriorUnionMountedTrue(t *testing.T) {
	pinRootModeChecked(t, lifecycle.RootModeChroot, errors.New("statfs boom"))
	r, runner, signals, statePath := unionMountProbeFixture(t, true)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if unionMountWasAttempted(runner) {
		t.Fatal("attempted a union mount despite an unresolved root-mode probe")
	}
	found := false
	for _, s := range *signals {
		if s == "reconciler:root_mode_probe_failed" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected reconciler:root_mode_probe_failed, got %v", *signals)
	}

	state, lerr := mount.LoadState(statePath)
	if lerr != nil {
		t.Fatalf("LoadState: %v", lerr)
	}
	if !state.UnionMounted {
		t.Error("UnionMounted must stay true when the union step is declined — a probe failure is not evidence the prior mount went away")
	}
}

// TestRunOnce_UnionMount_NativeRootSkipsMount is the non-error control: a
// resolved RootModeNative probe must take the bookkeeping-only branch (treat
// / as already the mounted union) and never call overlay.MountUnion —
// re-mounting a second overlay there is the exact kernel-UB case this whole
// gate exists to avoid.
func TestRunOnce_UnionMount_NativeRootSkipsMount(t *testing.T) {
	pinRootModeChecked(t, lifecycle.RootModeNative, nil)
	r, runner, signals, statePath := unionMountProbeFixture(t, false)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if unionMountWasAttempted(runner) {
		t.Fatal("a resolved native root must never take the shadow-overlay mount branch")
	}
	for _, s := range *signals {
		if s == "reconciler:root_mode_probe_failed" {
			t.Errorf("a successfully resolved probe must not signal root_mode_probe_failed, got %v", *signals)
		}
	}

	state, lerr := mount.LoadState(statePath)
	if lerr != nil {
		t.Fatalf("LoadState: %v", lerr)
	}
	if !state.UnionMounted {
		t.Error("a resolved native root must record UnionMounted=true (the live root IS the union)")
	}
}
