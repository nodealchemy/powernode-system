package runtime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

func renamedServiceFixture(digest, serviceName string) string {
	return `{"success": true, "data": {"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "digest":"` + digest + `",
	 "services": [{"name":"` + serviceName + `", "start_command":"/bin/true", "restart_policy":"always"}]}}`
}

// TestVersionBumpDetach_RenamedServiceStopsTheOldUnitNotTheNewOne is L6(b)'s
// red-first test (review round 7, LOW): detachModule resolved the manifest
// for the OLD digest being detached out of `manifests` — this tick's FRESH
// per-module-ID map, which for a version bump holds the NEW digest's
// manifest. A service renamed between the two digests (worker-v1 ->
// worker-v2) made DetachServices stop a unit that was never started (the
// new name) while the old digest's REAL, running unit was never named at
// all. Fixed via L1's digest-keyed attached-snapshot store, which resolves
// the manifest mod.Digest (the OLD one) was ACTUALLY attached with.
func TestVersionBumpDetach_RenamedServiceStopsTheOldUnitNotTheNewOne(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(t.TempDir(), "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules":    `{"success": true, "data": {"modules": [{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}]}}`,
		"/api/v1/system/node_api/modules/m1": renamedServiceFixture("abc123", "worker-v1"),
	}}
	runner := &mount.RecorderRunner{}
	r := versionBumpReconciler(t, tmpRoot, statePath, client, runner)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	oldUnit := lifecycle.UnitName("m1", "worker-v1")
	newUnit := lifecycle.UnitName("m1", "worker-v2")
	if !hasSystemctlOp(runner.Invocations, "start", oldUnit) {
		t.Fatalf("test setup: expected %s to start on pass 1, invocations: %v", oldUnit, runner.Invocations)
	}

	// Bump to a digest whose ONLY service was RENAMED, not merely edited.
	// Evicts ONLY the mutable per-ID manifest.json cache (forcing a refetch)
	// — NOT the whole per-module directory, which would also destroy L1's
	// digest-keyed attached-snapshot subdirectory this test means to prove
	// detachModule now reads from.
	client.responses["/api/v1/system/node_api/modules/m1"] = renamedServiceFixture("def456", "worker-v2")
	if err := os.Remove(filepath.Join(tmpRoot, "manifests", "m1", "manifest.json")); err != nil {
		t.Fatal(err)
	}

	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2 := runner.Invocations[pass2Start:]

	if !hasSystemctlOp(pass2, "stop", oldUnit) {
		t.Errorf("L6(b) REGRESSION: expected the OLD unit %s to be stopped on the renamed-service bump, invocations: %v", oldUnit, pass2)
	}
	if !hasSystemctlOp(pass2, "start", newUnit) {
		t.Errorf("expected the NEW unit %s to start on the renamed-service bump, invocations: %v", newUnit, pass2)
	}
}
