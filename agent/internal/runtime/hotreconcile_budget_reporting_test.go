package runtime

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// The FALSE-SUCCESS half of the scratch-budget abort, observed live on ops-hub
// 2026-09-04: hub-backend v92 and v93 logged `reconciler:recompose_budget: live
// materialization aborted ... scratch budget exhausted` on EVERY tick and never
// materialized a byte, while the platform's running_module_digests advanced to
// the new digest anyway. Every operator-visible signal said "deployed"; the node
// was running v91's files.
//
// The mechanism is entirely on the reporting side. RunOnce appends the module to
// current.AttachedModules BEFORE calling hotReconcileIfNeeded and deliberately
// leaves it there when the materialization is refused (the erofs layer really is
// attached — only the file copy was refused). buildHeartbeat then reports every
// AttachedModules entry's digest unconditionally as `module_digests`, which is
// what NodeInstance#record_heartbeat! writes to running_module_digests. So the
// heartbeat claims the node is RUNNING a version whose files it could not write.
//
// A node that cannot materialize a version must not report that version as
// running. Omitting the module is the honest answer and lands in an existing,
// already-tested consumer: the platform's drift check counts a heartbeated
// instance reporting no digest for an assigned module as DRIFTED (see
// platform_maintenance_executor_drift_check_spec.rb "counts a HEARTBEATED
// instance reporting no digests as drifted, not unknown"), which is exactly the
// signal the operator was denied.

// budgetReportingFixture builds the tick-2 pivot-node scenario the incident hit:
// module m1 already attached at digest d1, the platform now wants d2, and d2's
// mounted tree holds content that must be copied onto the live root.
//
// Returns the reconciler and the state path both it and the heartbeat read.
func budgetReportingFixture(t *testing.T) (*Reconciler, string) {
	t.Helper()
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")

	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()

	// Real prior state, so this is tick 2+ rather than the empty-state baseline
	// tick that hotReconcileIfNeeded correctly skips.
	emptyHash := (&manifest.Manifest{Services: []manifest.Service{}}).ServicesHash()
	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules:            []mount.Module{{ID: "m1", Digest: "d1", Priority: 100}},
		LastAttachedManifestHashes: map[string]string{"m1": emptyHash},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"hub-backend", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"hub-backend", "digest":"d2",
				         "priority":100, "effective_priority":100,
				         "reboot_required": false,
				         "services": []}
			}`,
		},
	}

	// Stand-in for what the erofs loop-mount of d2 would expose. RecorderRunner
	// never issues a real mount, so the content is placed directly.
	newMountDir := layout.ModuleMountPath("d2")
	mkdirAll(t, filepath.Join(newMountDir, "opt", "powernode", "server"))
	writeFile(t, filepath.Join(newMountDir, "opt", "powernode", "server", "BUILD_INFO.json"), `{"git_sha":"v92"}`)

	forcePivotNative(t)

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    &mount.RecorderRunner{},
		Layout:         layout,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	return r, statePath
}

// heartbeatFrom assembles the payload the agent would POST, reading the same
// state.json the reconciler just wrote — the real production path, not a
// hand-built payload.
func heartbeatFrom(t *testing.T, statePath string) HeartbeatPayload {
	t.Helper()
	svc := &Service{cfg: Config{
		AgentVersion: "test",
		StatePath:    statePath,
		OnError:      func(string, error) {},
	}}
	return svc.buildHeartbeat("boot-1", nil)
}

func TestHeartbeatOmitsDigestOfBudgetAbortedModule(t *testing.T) {
	r, statePath := budgetReportingFixture(t)

	// A free-space floor no filesystem can satisfy forces the budget abort
	// deterministically, rather than depending on the build machine's actual
	// free space. Same lever as TestHotReconcile_BudgetAbortRequestsRetry.
	r.cfg.ScratchMinFreeBytes = ^uint64(0) >> 1

	var signals []string
	r.cfg.OnError = func(kind string, _ error) { signals = append(signals, kind) }

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// Precondition, not the assertion under test: the abort really happened.
	// Without this a future change that silently stops aborting would leave the
	// real assertion below passing for the wrong reason.
	sawBudget := false
	for _, s := range signals {
		if s == "reconciler:recompose_budget" {
			sawBudget = true
		}
	}
	if !sawBudget {
		t.Fatalf("fixture did not reach the budget abort; signals=%v", signals)
	}

	payload := heartbeatFrom(t, statePath)
	if got, ok := payload.ModuleDigests["m1"]; ok {
		t.Fatalf("heartbeat reports m1 running digest %q after the materialization was REFUSED; "+
			"the platform records that as running_module_digests and the operator reads a successful deploy", got)
	}
}

// The control that stops the fix collapsing to "never report a digest": a module
// whose materialization SUCCEEDED must still be reported as running, or the node
// reads as permanently drifted and no deploy can ever be confirmed. This passes
// on HEAD — it is a guard, not evidence.
func TestHeartbeatStillReportsDigestOfMaterializedModule(t *testing.T) {
	r, statePath := budgetReportingFixture(t)
	// No ScratchMinFreeBytes override is not enough: scratchMinFreeBytes falls
	// back to DefaultScratchMinFreeBytes, so the guard is always armed. A floor
	// of one byte keeps the guard wired while letting the copy through.
	r.cfg.ScratchMinFreeBytes = 1

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	payload := heartbeatFrom(t, statePath)
	if payload.ModuleDigests["m1"] != "d2" {
		t.Fatalf("a materialized module must still be reported running; module_digests=%v", payload.ModuleDigests)
	}
}

// The abort must not LATCH. Once the scratch has room the next tick materializes
// the module, and the heartbeat has to start reporting it again — otherwise the
// fix trades a permanent false success for a permanent false drift.
func TestHeartbeatReportsDigestAgainOnceMaterializationSucceeds(t *testing.T) {
	r, statePath := budgetReportingFixture(t)
	r.cfg.ScratchMinFreeBytes = ^uint64(0) >> 1

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce (aborting tick): %v", err)
	}
	if _, ok := heartbeatFrom(t, statePath).ModuleDigests["m1"]; ok {
		t.Fatalf("precondition: the aborting tick must not report m1 as running")
	}

	// Scratch freed by hand — the incident's actual resolution.
	r.cfg.ScratchMinFreeBytes = 1
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce (recovered tick): %v", err)
	}

	if got := heartbeatFrom(t, statePath).ModuleDigests["m1"]; got != "d2" {
		t.Fatalf("after a successful materialization the heartbeat must report m1 at d2, got %q", got)
	}
}
