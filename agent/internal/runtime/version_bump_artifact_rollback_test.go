package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// backdateManifestCache pushes the on-disk manifest cache's mtime far enough
// into the past that NewReconciler's default 90s ManifestTTL treats it as
// stale on the NEXT RunOnce pass, WITHOUT deleting the file — unlike
// bumpModuleDigest (version_bump_detach_test.go), which evicts the cache
// outright. K2b's rollback needs RunOnce's OWN early previousManifests
// snapshot (captured before that pass's fetch loop overwrites the cache) to
// still find the OLD content on disk; bumpModuleDigest's eviction would
// destroy it before RunOnce ever got to look.
func backdateManifestCache(t *testing.T, manifestRoot, moduleID string) {
	t.Helper()
	path := filepath.Join(manifestRoot, moduleID, "manifest.json")
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("backdateManifestCache: %v", err)
	}
}

// digestFailingPuller wraps a stubPuller and fails Pull for one specific
// digest — used to simulate an artifact pull/verify problem the security
// pre-check (K1) has no way to see, since it never touches mounted content.
type digestFailingPuller struct {
	inner     *stubPuller
	failFor   string
	callCount int
}

func (p *digestFailingPuller) Pull(ref *oci.ModuleArtifactRef) (string, string, error) {
	p.callCount++
	if ref.Digest == p.failFor {
		return "", "", fmt.Errorf("stub pull failure for digest %s", ref.Digest)
	}
	return p.inner.Pull(ref)
}

// K2a (review round 6, CRITICAL): the security-policy pre-check is blind to
// an artifact pull/verify/mount failure — it never touches the module's
// mounted content. prefetchNewArtifacts now reports per-module success, and
// filterUnsafeVersionBumpDetaches consults it FIRST: an artifact that never
// even mounted must defer the old digest's detach exactly like a security
// refusal does.
func TestVersionBumpDetach_ArtifactPrefetchFailureDefersDetach(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(t.TempDir(), "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))

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
	puller := &digestFailingPuller{inner: &stubPuller{cacheDir: layout.ModulesCacheRoot}}
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

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "abc123" {
		t.Fatalf("pass 1: expected m1 attached at abc123, got digest=%q ok=%v", digest, ok)
	}

	// Bump the digest; the NEW digest's artifact pull fails outright.
	puller.failFor = "def456"
	bumpModuleDigest(t, filepath.Join(tmpRoot, "manifests"), "m1", client, "def456")

	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2Invocations := runner.Invocations[pass2Start:]

	if hasSystemctlOp(pass2Invocations, "stop", unit) {
		t.Errorf("K2a REGRESSION: pass 2 stopped %s even though the new digest's artifact never even mounted: %v", unit, pass2Invocations)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "abc123" {
		t.Errorf("K2a REGRESSION: pass 2 must leave m1 attached at the OLD digest abc123 when the new digest's artifact prefetch fails, got digest=%q ok=%v", digest, ok)
	}
}

// K2b (review round 6, CRITICAL): neither pre-check (security, K1; artifact
// readiness, K2a) can catch every real attach failure — a race where the
// artifact prefetch and security probe both succeed, but the REAL attach
// (Policy.Apply, a second mount attempt, ENOSPC that appears in between)
// still fails. Simulated here via a MountRunner that fails the SECOND
// "mount -t erofs" invocation for the new digest's mountpoint (prefetch's
// own call succeeds; attachModule's later call, inside the real attach
// loop, fails) — proving the failure genuinely happens AFTER prefetch
// already reported ready.
type failSecondMountRunner struct {
	*mount.RecorderRunner
	failDigest string
	mountCalls int
}

func (r *failSecondMountRunner) Run(ctx context.Context, name string, args ...string) error {
	if name == "mount" && containsArg(args, "-t") {
		isTarget := false
		for _, a := range args {
			if filepath.Base(a) == r.failDigest+".erofs" {
				isTarget = true
			}
		}
		if isTarget {
			r.mountCalls++
			r.RecorderRunner.Invocations = append(r.RecorderRunner.Invocations, mount.Invocation{Op: "Run", Name: name, Args: append([]string(nil), args...)})
			if r.mountCalls >= 2 {
				return fmt.Errorf("stub: mount failed on attempt %d for digest %s", r.mountCalls, r.failDigest)
			}
			return nil
		}
	}
	return r.RecorderRunner.Run(ctx, name, args...)
}

func TestVersionBumpDetach_RealAttachFailureAfterDetachRollsBackOldDigest(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(t.TempDir(), "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))

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
	recorder := &mount.RecorderRunner{}
	runner := &failSecondMountRunner{RecorderRunner: recorder, failDigest: "def456"}
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

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "abc123" {
		t.Fatalf("pass 1: expected m1 attached at abc123, got digest=%q ok=%v", digest, ok)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = versionBumpFixture("def456")
	backdateManifestCache(t, filepath.Join(tmpRoot, "manifests"), "m1")

	pass2Start := len(recorder.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2Invocations := recorder.Invocations[pass2Start:]

	if !hasSystemctlOp(pass2Invocations, "start", unit) {
		t.Errorf("K2b REGRESSION: expected a rollback re-start of %s after the new digest's real attach failed post-detach, invocations: %v", unit, recorder.Invocations)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "abc123" {
		t.Errorf("K2b REGRESSION: expected state to show ONLY the OLD digest abc123 restored after rollback, got digest=%q ok=%v", digest, ok)
	}
	// Never both digests at once.
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	count := 0
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			count++
		}
	}
	if count != 1 {
		t.Errorf("K2b/K3 REGRESSION: expected exactly one m1 entry in AttachedModules after rollback, got %d: %+v", count, st.AttachedModules)
	}
}
