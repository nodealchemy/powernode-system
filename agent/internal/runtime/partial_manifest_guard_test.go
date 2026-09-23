package runtime

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// ageManifestCache backdates a just-written manifest cache file's mtime past
// the reconciler's default ManifestTTL (90s), so manifest.LoadOrFetch treats
// it as stale and actually calls the (stubbed) client instead of silently
// short-circuiting on the fixture's own fresh write — the exact trap the
// review's B2 test regression hit: a fresh-mtime fixture never reaches the
// stub at all, so a test meant to exercise a FAILED re-fetch of an
// already-cached module measures nothing.
func ageManifestCache(t *testing.T, path string) {
	t.Helper()
	old := time.Now().Add(-1 * time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("Chtimes: %v", err)
	}
}

// IMP-2dfbd7f62441 — verified from the 2026-09-22 ops-hub outage: a reconcile
// tick where FetchAssignedModules succeeds but a per-module manifest.LoadOrFetch
// 502s (rails restarting mid-tick) left the manifest set PARTIAL, and RunOnce
// rendered /etc/passwd + sudoers from that partial view anyway — deleting every
// module-declared user the failed fetch happened to omit. This file pins the
// guards that stop that, revised per the 2026-09-23 independent review
// (findings B1/B2/N1/N3/N4):
//
//   - identity/sudoers/egress render from the RETAINED set (what's actually
//     still attached this tick, see retainedAfterDetach), not from `desired`
//     (only what this tick could freshly fetch) — a module can stay attached
//     without ever entering `desired` (B1).
//   - a retained module missing a fresh manifest falls back to its last
//     CACHED one rather than freezing or dropping the whole render (B2).
//   - a fetch that succeeded but only failed to WRITE its cache is not
//     treated as a fetch failure (N1).
//   - the detach diff defers a genuine fetch failure but still detaches a
//     module that is simply no longer assigned at all (N4).

// TestReconcilerRendersIdentityAndSudoersWhenAllManifestsLoad is the positive
// control (review finding N4(a)): without it, a broken guard that never calls
// applyIdentity/applySudoers at all would pass every "must be skipped on
// failure" test in this file by accident.
func TestReconcilerRendersIdentityAndSudoersWhenAllManifestsLoad(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"nginx", "priority":100, "effective_priority":100, "has_data_file":true},
					{"id":"m2", "name":"ok", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"nginx", "digest":"abc123",
				         "priority":100, "effective_priority":100}
			}`,
			"/api/v1/system/node_api/modules/m2": `{
				"success": true,
				"data": {"id":"m2", "name":"ok", "digest":"def456",
				         "priority":100, "effective_priority":100}
			}`,
		},
	}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	var identityCalled, sudoersCalled bool
	origIdentity, origSudoers := applyIdentity, applySudoers
	applyIdentity = func(*etcidentity.Set) error { identityCalled = true; return nil }
	applySudoers = func([]etcsudoers.Grant) error { sudoersCalled = true; return nil }
	t.Cleanup(func() { applyIdentity, applySudoers = origIdentity, origSudoers })

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
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if !identityCalled {
		t.Error("expected etcidentity.Apply to run when every assigned module's manifest loaded cleanly")
	}
	if !sudoersCalled {
		t.Error("expected etcsudoers.Apply to run when every assigned module's manifest loaded cleanly")
	}
}

// TestReconcilerRendersIdentityDespiteAnUnrelatedNewModulesFetchFailure covers
// a NEW (never-before-attached) module's fetch failure: it must not freeze or
// skip the render for every OTHER module. m2 here is not "retained" (it was
// never attached) AND not present in the boot breadcrumb (this test writes
// none, and TestMain sandboxes BootBreadcrumbPath to a path that never
// exists), so per review finding R2-B1's categorization it is "genuinely
// new" — its failure carries no weight for the render at all, distinct from
// TestReconcilerPreservesRetainedModuleIdentityWhenAssignedListOmitsIt and
// TestReconcilerResolvesIdentityFromTheBootBreadcrumbWhenStateIsEmpty below,
// where the failing module WAS real (retained or boot-composed) and must
// resolve via a fallback instead of being silently omitted.
func TestReconcilerRendersIdentityDespiteAnUnrelatedNewModulesFetchFailure(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"nginx", "priority":100, "effective_priority":100, "has_data_file":true},
					{"id":"m2", "name":"broken", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"nginx", "digest":"abc123",
				         "priority":100, "effective_priority":100}
			}`,
			// m2's manifest fetch 502s -- rails restarting mid-tick, the
			// exact shape observed live 2026-09-22 -- but m2 was NEVER
			// attached before, so it cannot be "retained".
			"/api/v1/system/node_api/modules/m2": `{"success":false,"error":"boom"}`,
		},
		statuses: map[string]int{
			"/api/v1/system/node_api/modules/m2": 502,
		},
	}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	var identityCalled, sudoersCalled bool
	origIdentity, origSudoers := applyIdentity, applySudoers
	applyIdentity = func(*etcidentity.Set) error { identityCalled = true; return nil }
	applySudoers = func([]etcsudoers.Grant) error { sudoersCalled = true; return nil }
	t.Cleanup(func() { applyIdentity, applySudoers = origIdentity, origSudoers })

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
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if !identityCalled {
		t.Error("a brand-new module's fetch failure must not block the identity render for every other module")
	}
	if !sudoersCalled {
		t.Error("a brand-new module's fetch failure must not block the sudoers render for every other module")
	}
}

// TestReconcilerRendersNewModuleWhileRetainingAFailingModulesCachedIdentity is
// review finding B2's test: a RETAINED module failing every tick must not
// freeze the render forever, and must not lose its own last-known identity
// either — both properties in the same pass.
func TestReconcilerRendersNewModuleWhileRetainingAFailingModulesCachedIdentity(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	manifestRoot := filepath.Join(tmpRoot, "manifests")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	// "failing" was attached in a PRIOR tick; its manifest cache from that
	// tick declares a user. THIS tick its fetch 502s again.
	mkdirAll(t, filepath.Join(manifestRoot, "failing"))
	failingCachePath := filepath.Join(manifestRoot, "failing", "manifest.json")
	writeFile(t, failingCachePath,
		`{"id":"failing","name":"failing","digest":"d-failing","priority":100,"effective_priority":100,
		  "users":[{"name":"svc-failing","uid":6001,"primary_gid":6001}]}`)
	// Backdate the cache past ManifestTTL so LoadOrFetch actually calls the
	// (stubbed, 502ing) client below instead of short-circuiting on this
	// fixture's own fresh write.
	ageManifestCache(t, failingCachePath)

	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{{ID: "failing", Digest: "d-failing", Priority: 100}},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"failing", "name":"failing", "priority":100, "effective_priority":100, "has_data_file":true},
					{"id":"newmod", "name":"newmod", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			// failing's fetch 502s AGAIN this tick.
			"/api/v1/system/node_api/modules/failing": `{"success":false,"error":"boom"}`,
			"/api/v1/system/node_api/modules/newmod": `{
				"success": true,
				"data": {"id":"newmod", "name":"newmod", "digest":"d-new",
				         "priority":100, "effective_priority":100,
				         "users":[{"name":"svc-new","uid":6002,"primary_gid":6002}]}
			}`,
		},
		statuses: map[string]int{
			"/api/v1/system/node_api/modules/failing": 502,
		},
	}
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	var captured *etcidentity.Set
	origIdentity := applyIdentity
	applyIdentity = func(set *etcidentity.Set) error { captured = set; return nil }
	t.Cleanup(func() { applyIdentity = origIdentity })

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if captured == nil {
		t.Fatalf("identity render did not run")
	}
	got := map[string]bool{}
	for _, u := range captured.Users {
		got[u.Name] = true
	}
	if !got["svc-failing"] {
		t.Errorf("the failing (retained) module's CACHED identity must survive; got users=%+v", captured.Users)
	}
	if !got["svc-new"] {
		t.Errorf("the new module's FRESH identity must render in the SAME pass; got users=%+v", captured.Users)
	}
}

// TestReconcilerPreservesRetainedModuleIdentityWhenAssignedListOmitsIt is
// review finding B1's test: a self-hosted node whose assigned-modules list
// comes back 200 but simply OMITS an attached module (never entering the
// manifest-fetch loop at all, so manifestFetchFailed never sees it either)
// must still preserve that module's declared users — it is kept attached by
// the pre-existing self-host detach guard (filterUnsafeDetaches), and the
// identity render must agree with that, not silently drop its users.
func TestReconcilerPreservesRetainedModuleIdentityWhenAssignedListOmitsIt(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	manifestRoot := filepath.Join(tmpRoot, "manifests")

	// Seed the on-disk manifest cache for "rails" as if a prior tick had
	// fetched it. This tick's assigned-modules response omits it entirely.
	// digest MUST match the digest state.json records as attached below
	// (review finding R2-N2): the resolution loop rejects a cached fallback
	// whose digest disagrees with what's actually mounted.
	mkdirAll(t, filepath.Join(manifestRoot, "rails"))
	writeFile(t, filepath.Join(manifestRoot, "rails", "manifest.json"),
		`{"id":"rails","name":"rails","digest":"d-rails","priority":100,"effective_priority":100,
		  "services":[{"name":"rails","start_command":"/usr/bin/rails-start"}],
		  "users":[{"name":"powernode-rails","uid":5000,"primary_gid":5000}]}`)

	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{{ID: "rails", Digest: "d-rails", Priority: 100}},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	// Self-hosted: this node's platform URL resolves to one of its own
	// addresses (same seam/fixture values as selfhost_test.go's
	// detachFixture(t, true)).
	withLookups(t, map[string][]string{"h": {"10.0.0.1"}}, []string{"10.0.0.1"}, nil)

	client := &stubModulesClient{
		responses: map[string]string{
			// Degraded-but-200 list: entirely omits "rails", the module
			// that is actually running this node's own control plane.
			"/api/v1/system/node_api/modules": `{"success": true, "data": {"modules": []}}`,
		},
	}
	runner := &mount.RecorderRunner{}

	var captured *etcidentity.Set
	origIdentity := applyIdentity
	applyIdentity = func(set *etcidentity.Set) error { captured = set; return nil }
	t.Cleanup(func() { applyIdentity = origIdentity })

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
		PlatformURL:    "https://h",
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if captured == nil {
		t.Fatalf("identity render did not run")
	}
	found := false
	for _, u := range captured.Users {
		if u.Name == "powernode-rails" {
			found = true
		}
	}
	if !found {
		t.Errorf("powernode-rails must survive via the cached-manifest fallback even though the assigned list omitted it this tick; got users=%+v", captured.Users)
	}

	// Sanity: rails also stays attached (the pre-existing self-host detach
	// guard, filterUnsafeDetaches, unaffected by this change).
	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	stillAttached := false
	for _, m := range state.AttachedModules {
		if m.ID == "rails" {
			stillAttached = true
		}
	}
	if !stillAttached {
		t.Errorf("rails should stay attached on a self-hosted node even when omitted from the assigned list")
	}
}

// TestReconcilerDetachesAnUnassignedModuleButDefersAFetchFailure is review
// finding N4(b): the detach diff must tell apart "genuinely no longer
// assigned" (m3, absent from the list entirely — a real removal, must
// detach) from "assigned but this tick's fetch failed" (m2 — must defer),
// on a NON-self-hosted node (filterUnsafeDetaches is a no-op here, so only
// filterUnverifiedDetaches is protecting m2).
func TestReconcilerDetachesAnUnassignedModuleButDefersAFetchFailure(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	// Pre-seed: m2 and m3 both already attached from a prior successful tick.
	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m2", Digest: "d2", Priority: 100},
			{ID: "m3", Digest: "d3", Priority: 100},
		},
		LastAttachedManifestHashes: map[string]string{
			"m2": testAttachStamp("m2", nil),
			"m3": testAttachStamp("m3", nil),
		},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			// m2 is still assigned (its fetch will 502 below); m3 is
			// entirely ABSENT -- a real, unambiguous unassignment.
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m2", "name":"broken", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m2": `{"success":false,"error":"boom"}`,
		},
		statuses: map[string]int{
			"/api/v1/system/node_api/modules/m2": 502,
		},
	}
	runner := &mount.RecorderRunner{}

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
		// PlatformURL intentionally empty: not self-hosted, so
		// filterUnsafeDetaches is a no-op — only filterUnverifiedDetaches
		// can be protecting m2 here.
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	attached := map[string]bool{}
	for _, m := range state.AttachedModules {
		attached[m.ID] = true
	}
	if !attached["m2"] {
		t.Errorf("m2 must NOT be detached: this tick's fetch failure is not a real unassignment; got AttachedModules=%+v", state.AttachedModules)
	}
	if attached["m3"] {
		t.Errorf("m3 MUST be detached: it is genuinely absent from the assigned list, not a fetch failure; got AttachedModules=%+v", state.AttachedModules)
	}
}

// TestReconcilerUsesManifestWhenOnlyTheCacheWriteFailed is review finding
// N1's test: manifest.FetchAndCache (internal/manifest/loader.go) returns a
// VALID manifest alongside a non-nil error when only the on-disk cache WRITE
// failed. Treating that as a fetch failure would manufacture a partial view
// out of a write-side problem, dropping a module the platform actually
// answered about.
func TestReconcilerUsesManifestWhenOnlyTheCacheWriteFailed(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	// Pre-create the manifest.json LEAF as a DIRECTORY (review finding
	// R2-N5: CI runs this suite as root, where a mere permission bit — the
	// original 0o555-parent-dir trick — is no obstacle to root's
	// DAC_OVERRIDE). fsutil.AtomicWrite's final step is os.Rename(tmpFile,
	// path); rename(2) refuses to replace an existing DIRECTORY with a
	// regular file (EISDIR) regardless of privilege — a filesystem type
	// invariant, not a permission check — so the cache write fails even as
	// root. os.Stat on this path succeeds (it exists), so LoadOrFetch takes
	// its normal "read from disk" branch first; os.ReadFile on a directory
	// returns EISDIR too, which LoadOrFetch's own comment already treats as
	// "the cache file is corrupt; refresh it" and falls through to
	// FetchAndCache — only the WRITE inside that fails.
	manifestRoot := filepath.Join(tmpRoot, "manifests")
	mkdirAll(t, filepath.Join(manifestRoot, "m1", "manifest.json"))

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"nginx", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"nginx", "digest":"abc123",
				         "priority":100, "effective_priority":100}
			}`,
		},
	}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	var stages []string
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
		OnError:        func(stage string, _ error) { stages = append(stages, stage) },
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// The module attached anyway -- a cache-WRITE failure must not be
	// mistaken for a fetch failure: the fetch itself succeeded, so m1
	// belongs in `desired` and gets attached normally.
	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if len(state.AttachedModules) != 1 || state.AttachedModules[0].ID != "m1" {
		t.Errorf("expected m1 attached despite the cache-write failure, got %+v", state.AttachedModules)
	}

	foundCacheWriteSignal := false
	for _, s := range stages {
		if s == "reconciler:manifest_cache_write_failed" {
			foundCacheWriteSignal = true
		}
		if s == "reconciler:fetch_manifest" {
			t.Errorf("a cache-write-only failure must not be logged as a fetch failure")
		}
	}
	if !foundCacheWriteSignal {
		t.Errorf("expected a reconciler:manifest_cache_write_failed signal, got stages=%v", stages)
	}
}

// TestReconcilerSkipsRenderRatherThanLoseAnAttachedModulesUsersAcrossTicks is
// review finding R2-B1 route (1): a module whose cache write fails on the
// tick that attaches it (so it is rendered from the FRESH manifest, per N1,
// but the on-disk cache never actually gets written), then fails to fetch
// entirely on a LATER tick, must not simply be treated as "retained + no
// cache -> omitted" (that is exactly how the 2026-09-22 outage happened: a
// module's users disappear from the render). It must instead SKIP the
// render for the tick it cannot resolve, leaving the earlier good render
// (which DID include its users) untouched.
func TestReconcilerSkipsRenderRatherThanLoseAnAttachedModulesUsersAcrossTicks(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	// The manifest.json LEAF is a DIRECTORY for the whole test (same
	// root-proof trick as TestReconcilerUsesManifestWhenOnlyTheCacheWriteFailed):
	// every cache WRITE for m1 fails, persistently, tick after tick.
	manifestRoot := filepath.Join(tmpRoot, "manifests")
	mkdirAll(t, filepath.Join(manifestRoot, "m1", "manifest.json"))

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"nginx", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			// Tick 1: fetch succeeds with real content.
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"nginx", "digest":"d1",
				         "priority":100, "effective_priority":100,
				         "users":[{"name":"svc-m1","uid":7001,"primary_gid":7001}]}
			}`,
		},
	}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	var identityCalls int
	var lastCaptured *etcidentity.Set
	origIdentity := applyIdentity
	applyIdentity = func(set *etcidentity.Set) error {
		identityCalls++
		lastCaptured = set
		return nil
	}
	t.Cleanup(func() { applyIdentity = origIdentity })

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}

	// Tick 1.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce (tick 1): %v", err)
	}
	if identityCalls != 1 {
		t.Fatalf("expected identity render to run on tick 1, got %d calls", identityCalls)
	}
	found := false
	for _, u := range lastCaptured.Users {
		if u.Name == "svc-m1" {
			found = true
		}
	}
	if !found {
		t.Fatalf("tick 1 must render svc-m1 despite the cache-write failure (review finding N1); got users=%+v", lastCaptured.Users)
	}

	// Tick 2: the fetch itself now fails outright (502) -- and the cache
	// was never actually written (still a directory), so there is no
	// fallback for m1 either. m1 IS retained (attached from tick 1), so
	// this must SKIP the render entirely rather than omit m1.
	client.responses["/api/v1/system/node_api/modules/m1"] = `{"success":false,"error":"boom"}`
	client.statuses = map[string]int{"/api/v1/system/node_api/modules/m1": 502}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce (tick 2): %v", err)
	}
	if identityCalls != 1 {
		t.Errorf("tick 2 must SKIP the identity render (m1 is retained but unresolvable via fresh/cache/breadcrumb); got %d total calls, want 1 (tick 1's render, unchanged)", identityCalls)
	}
}

// TestReconcilerResolvesIdentityFromTheBootBreadcrumbWhenStateIsEmpty is
// review finding R2-B1 route (2): on a tick where state.json is empty (e.g. a
// reprovisioned /persist, or the first tick after boot) `retained` has
// nothing to say — but ComposeForPivot already rendered real users into the
// live union from the boot breadcrumb. A module whose fetch fails on that
// tick must still resolve through the breadcrumb's embedded manifest rather
// than being treated as brand new and silently omitted.
func TestReconcilerResolvesIdentityFromTheBootBreadcrumbWhenStateIsEmpty(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json") // no pre-seed: empty state.json
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	origBC := BootBreadcrumbPath
	BootBreadcrumbPath = filepath.Join(tmpRoot, "boot-composed.json")
	t.Cleanup(func() { BootBreadcrumbPath = origBC })

	m1Manifest := manifest.Manifest{
		ID: "m1", Name: "compose-rendered", Digest: "d1",
		Users: []manifest.ManifestUser{{Name: "svc-m1", UID: 7001, PrimaryGID: 7001}},
	}
	rawM1, err := json.Marshal(m1Manifest)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if err := WriteBreadcrumb(BootBreadcrumbPath, &BootComposedBreadcrumb{
		SchemaVersion: 1,
		Modules: []LKGModule{
			{ID: "m1", Name: "compose-rendered", HasDataFile: true, Digest: "d1", Manifest: rawM1},
		},
	}); err != nil {
		t.Fatalf("WriteBreadcrumb: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"compose-rendered", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			// This tick's fetch fails outright.
			"/api/v1/system/node_api/modules/m1": `{"success":false,"error":"boom"}`,
		},
		statuses: map[string]int{
			"/api/v1/system/node_api/modules/m1": 502,
		},
	}
	runner := &mount.RecorderRunner{}

	var captured *etcidentity.Set
	origIdentity := applyIdentity
	applyIdentity = func(set *etcidentity.Set) error { captured = set; return nil }
	t.Cleanup(func() { applyIdentity = origIdentity })

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if captured == nil {
		t.Fatalf("identity render did not run")
	}
	found := false
	for _, u := range captured.Users {
		if u.Name == "svc-m1" {
			found = true
		}
	}
	if !found {
		t.Errorf("svc-m1 must resolve via the boot breadcrumb even though state.json is empty (retained is empty too); got users=%+v", captured.Users)
	}
}

// TestReconcilerResolvesIdentityFromBreadcrumbDataModuleAbsentFromStateAndAssignedList
// is round-4 review finding #1: distinct from the route (2) test above (where
// m1 is at least ASSIGNED and its fetch fails, so manifestFetchFailed already
// carries it), here m1 is entirely ABSENT from BOTH state.json AND this
// tick's assigned-modules list — it never becomes "retained" (state never
// named it) and never becomes "fetch-failed" (never even attempted). Only
// the current boot's breadcrumb data-module set can surface it as a
// candidate at all; without that, its users would be dropped with no signal
// whatsoever.
func TestReconcilerResolvesIdentityFromBreadcrumbDataModuleAbsentFromStateAndAssignedList(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json") // empty state.json
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	origBC := BootBreadcrumbPath
	BootBreadcrumbPath = filepath.Join(tmpRoot, "boot-composed.json")
	t.Cleanup(func() { BootBreadcrumbPath = origBC })

	m1Manifest := manifest.Manifest{
		ID: "m1", Name: "compose-rendered", Digest: "d1",
		Users: []manifest.ManifestUser{{Name: "svc-m1", UID: 7001, PrimaryGID: 7001}},
	}
	rawM1, err := json.Marshal(m1Manifest)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if err := WriteBreadcrumb(BootBreadcrumbPath, &BootComposedBreadcrumb{
		SchemaVersion: 1,
		Modules: []LKGModule{
			{ID: "m1", Name: "compose-rendered", HasDataFile: true, Digest: "d1", Manifest: rawM1},
		},
	}); err != nil {
		t.Fatalf("WriteBreadcrumb: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			// m1 is entirely ABSENT here -- never assigned this tick at
			// all, so it never reaches the manifest-fetch loop and never
			// enters manifestFetchFailed either.
			"/api/v1/system/node_api/modules": `{"success": true, "data": {"modules": []}}`,
		},
	}
	runner := &mount.RecorderRunner{}

	var captured *etcidentity.Set
	origIdentity := applyIdentity
	applyIdentity = func(set *etcidentity.Set) error { captured = set; return nil }
	t.Cleanup(func() { applyIdentity = origIdentity })

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if captured == nil {
		t.Fatalf("identity render did not run")
	}
	found := false
	for _, u := range captured.Users {
		if u.Name == "svc-m1" {
			found = true
		}
	}
	if !found {
		t.Errorf("svc-m1 must resolve via the CURRENT boot's breadcrumb even though m1 is absent from BOTH state.json and this tick's assigned list; got users=%+v", captured.Users)
	}
}

// TestReconcilerIgnoresABreadcrumbFromADifferentBoot is round-4 review
// finding #2: a failed breadcrumb write on THIS boot leaves the PREVIOUS
// boot's file on disk, same rationale as lkg_capture.go's own promotion
// guard (which this mirrors). A stale breadcrumb must not be trusted as
// "this boot genuinely composed it" — m1 here has no other source (not
// retained, never assigned this tick), so it must fall through to
// "genuinely new, harmless to omit" rather than resolving from stale data.
func TestReconcilerIgnoresABreadcrumbFromADifferentBoot(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	origBC := BootBreadcrumbPath
	BootBreadcrumbPath = filepath.Join(tmpRoot, "boot-composed.json")
	t.Cleanup(func() { BootBreadcrumbPath = origBC })

	m1Manifest := manifest.Manifest{
		ID: "m1", Name: "compose-rendered", Digest: "d1",
		Users: []manifest.ManifestUser{{Name: "svc-m1", UID: 7001, PrimaryGID: 7001}},
	}
	rawM1, err := json.Marshal(m1Manifest)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if err := WriteBreadcrumb(BootBreadcrumbPath, &BootComposedBreadcrumb{
		SchemaVersion: 1,
		BootID:        "stale-boot-id-does-not-exist",
		Modules: []LKGModule{
			{ID: "m1", Name: "compose-rendered", HasDataFile: true, Digest: "d1", Manifest: rawM1},
		},
	}); err != nil {
		t.Fatalf("WriteBreadcrumb: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{"success": true, "data": {"modules": []}}`,
		},
	}
	runner := &mount.RecorderRunner{}

	var identityCalled bool
	var captured *etcidentity.Set
	origIdentity := applyIdentity
	applyIdentity = func(set *etcidentity.Set) error { identityCalled = true; captured = set; return nil }
	t.Cleanup(func() { applyIdentity = origIdentity })

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// m1 is not retained, not fetch-failed (never assigned), and its ONLY
	// possible source -- the breadcrumb -- must be ignored as stale. It is
	// therefore "genuinely new" (harmless to omit): identity still renders
	// normally, just without m1.
	if !identityCalled {
		t.Fatal("expected the identity render to run normally, ignoring the stale breadcrumb entirely")
	}
	for _, u := range captured.Users {
		if u.Name == "svc-m1" {
			t.Errorf("svc-m1 must NOT resolve from a breadcrumb whose BootID names a different boot; got users=%+v", captured.Users)
		}
	}
}

// TestReconcilerRejectsACachedManifestWhoseDigestDisagreesWithWhatsMounted is
// review finding R2-N2: a retained module's currently-mounted Digest is the
// ground truth. A cached manifest describing a DIFFERENT digest belongs to a
// different version and must not be used as this module's fallback — it is
// exactly as unresolved as no cache at all, which (with no breadcrumb either,
// in this test) means the render must SKIP rather than render mismatched
// content.
func TestReconcilerRejectsACachedManifestWhoseDigestDisagreesWithWhatsMounted(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	manifestRoot := filepath.Join(tmpRoot, "manifests")

	// Cached manifest describes digest "d-old" -- a PRIOR version -- but
	// state.json (below) records "m1" as attached at "d-new".
	mkdirAll(t, filepath.Join(manifestRoot, "m1"))
	writeFile(t, filepath.Join(manifestRoot, "m1", "manifest.json"),
		`{"id":"m1","name":"m1","digest":"d-old","priority":100,"effective_priority":100,
		  "users":[{"name":"svc-old","uid":8001,"primary_gid":8001}]}`)

	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{{ID: "m1", Digest: "d-new", Priority: 100}},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			// m1 is omitted from the assigned list entirely this tick, so
			// the ONLY candidate source is the (digest-mismatched) cache.
			"/api/v1/system/node_api/modules": `{"success": true, "data": {"modules": []}}`,
		},
	}
	runner := &mount.RecorderRunner{}

	var identityCalled bool
	origIdentity := applyIdentity
	applyIdentity = func(*etcidentity.Set) error { identityCalled = true; return nil }
	t.Cleanup(func() { applyIdentity = origIdentity })

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
		PlatformURL:    "https://h",
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	withLookups(t, map[string][]string{"h": {"10.0.0.1"}}, []string{"10.0.0.1"}, nil)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if identityCalled {
		t.Error("a cached manifest whose digest disagrees with the actually-mounted module must be rejected, not rendered — the render should have been skipped instead")
	}
}

// TestReconcilerSkipsEgressRebuildWhenTheRenderIsUnresolved is review finding
// R2-N3: the egress rebuild is gated on the SAME predicate as identity/
// sudoers. On an unresolved tick, neither ApplyEgressAllowlistWithProtected
// NOR RemoveEgressAllowlist must run — an existing enforcing chain must
// survive untouched rather than being silently rebuilt without an
// unresolved module's allow entries, or torn down because this tick's
// (incomplete) view looked like nobody wants enforcement.
func TestReconcilerSkipsEgressRebuildWhenTheRenderIsUnresolved(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")

	// m1 is retained (attached at d-new) but its only fallback (cache)
	// describes a different digest -- unresolved, same shape as the R2-N2
	// test above, which is what drives mustSkipRender here.
	manifestRoot := filepath.Join(tmpRoot, "manifests")
	mkdirAll(t, filepath.Join(manifestRoot, "m1"))
	writeFile(t, filepath.Join(manifestRoot, "m1", "manifest.json"),
		`{"id":"m1","name":"m1","digest":"d-old","priority":100,"effective_priority":100}`)

	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{{ID: "m1", Digest: "d-new", Priority: 100}},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{"success": true, "data": {"modules": []}}`,
		},
	}
	runner := &mount.RecorderRunner{}

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
		PlatformURL:    "https://h",
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	withLookups(t, map[string][]string{"h": {"10.0.0.1"}}, []string{"10.0.0.1"}, nil)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	for _, inv := range runner.Invocations {
		if inv.Name == "nft" {
			t.Errorf("no nft invocation must occur on an unresolved tick, got: %+v", inv)
		}
	}
}

// TestReconcilerAppliesEgressWhenTheRenderIsFullyResolved is the positive
// control for TestReconcilerSkipsEgressRebuildWhenTheRenderIsUnresolved: a
// normal, fully-resolved tick must still enforce egress exactly as before —
// proving the R2-N3 gate does not silently disable egress altogether.
func TestReconcilerAppliesEgressWhenTheRenderIsFullyResolved(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"claude-tmux", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"claude-tmux", "digest":"d1",
				         "priority":100, "effective_priority":100,
				         "config": {"security": {"egress_allow": []}},
				         "services": [{"name":"claude", "start_command":"/usr/bin/claude", "restart_policy":"always"}]}
			}`,
		},
	}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

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
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	foundChain := false
	for _, inv := range runner.Invocations {
		if inv.Name == "nft" && len(inv.Args) >= 3 && inv.Args[0] == "add" && inv.Args[1] == "chain" {
			foundChain = true
		}
	}
	if !foundChain {
		t.Errorf("expected an egress chain install on a fully-resolved tick, got invocations: %+v", runner.Invocations)
	}
}

// TestProcessPendingPrunes_RetainedButUnresolvedSurvivorMustSurviveAPrune is
// review finding N3/R2-N4's direct test, at the same unit level as
// hotleaver_test.go's own TestPendingPrune_OneTickDeferralThenExecution: a
// module RunOnce could not resolve a manifest for this tick is still a real,
// mounted layer, and desiredForLayers (unlike bare `desired`) carries it into
// processPendingPrunes precisely so survivingLayerDirs can see it. This test
// exercises processPendingPrunes directly with a stack shaped exactly like
// desiredForLayers would produce for a retained-but-unresolved survivor —
// proving the shared path is RESTORED from survivor rather than deleted as
// "nobody else has this".
func TestProcessPendingPrunes_RetainedButUnresolvedSurvivorMustSurviveAPrune(t *testing.T) {
	r, layout, _ := leaverFixture(t)
	survivor := mount.Module{ID: "survivor", Digest: "sha256:survivor", Priority: 200}
	hpWriteFile(t, layout.ModuleMountPath(survivor.Digest), "opt/shared/file.txt", "survivor-content")
	// What the live root currently serves at that path (as if leaver's
	// content had been hot-copied there on an earlier tick).
	hpWriteFile(t, layout.Root, "opt/shared/file.txt", "leaver-content")

	r.writePendingPrunes([]pendingPruneRecord{{
		ModuleID: "leaver", Digest: "sha256:leavergone",
		Files: []string{"/opt/shared/file.txt"},
	}})

	// Pass 1 (tick T): arms, prunes nothing yet.
	r.processPendingPrunes(mount.ModuleStack{survivor})
	// Pass 2 (tick T+1): executes. survivor IS in the passed stack — the
	// same shape desiredForLayers guarantees for a retained-but-unresolved
	// module — so the shared path must be RESTORED from survivor, not
	// deleted.
	r.processPendingPrunes(mount.ModuleStack{survivor})

	got, err := os.ReadFile(filepath.Join(layout.Root, "opt/shared/file.txt"))
	if err != nil {
		t.Fatalf("expected the shared path to survive (restored from survivor), got error: %v", err)
	}
	if string(got) != "survivor-content" {
		t.Errorf("expected content restored from survivor, got %q", got)
	}
}

// TestProcessPendingPrunes_OmittingASurvivorFromTheLayerStackDeletesItsPath
// is the contrasting case: when the passed stack does NOT include survivor
// (the shape bare `desired` would have produced pre-fix, since a
// retained-but-unresolved module never enters `desired`), the shared path is
// wrongly deleted. This is what makes desiredForLayers's inclusion of such a
// module load-bearing rather than cosmetic.
func TestProcessPendingPrunes_OmittingASurvivorFromTheLayerStackDeletesItsPath(t *testing.T) {
	r, layout, _ := leaverFixture(t)
	hpWriteFile(t, layout.ModuleMountPath("sha256:survivor"), "opt/shared/file.txt", "survivor-content")
	hpWriteFile(t, layout.Root, "opt/shared/file.txt", "leaver-content")

	r.writePendingPrunes([]pendingPruneRecord{{
		ModuleID: "leaver", Digest: "sha256:leavergone",
		Files: []string{"/opt/shared/file.txt"},
	}})

	r.processPendingPrunes(nil) // arm
	r.processPendingPrunes(nil) // execute -- nothing in the passed stack claims the path

	if _, err := os.Stat(filepath.Join(layout.Root, "opt/shared/file.txt")); !os.IsNotExist(err) {
		t.Errorf("expected the shared path deleted when no layer in the passed stack claims it (demonstrating why desiredForLayers must include survivor), stat err=%v", err)
	}
}

// TestReconcilerRunOncePrunesThroughDesiredForLayersNotBareDesired is the
// review's round-4 finding #4: a RunOnce-LEVEL test pinning the WIRING, not
// just the processPendingPrunes contract the two tests above already cover
// at the unit level. It would fail if any of the three call sites
// (hotReconcileIfNeeded x2, processPendingPrunes) reverted to passing bare
// `desired` instead of desiredForLayers: "survivor" is retained but this
// tick's fetch fails and it has neither a cache nor a breadcrumb, so it is
// unresolved and never enters `desired` at all — only desiredForLayers
// carries it. "leaver" is genuinely unassigned (absent from the list
// entirely) and shares a live-root path with survivor; a real leaver prune
// must see survivor as a surviving layer or it deletes that path.
func TestReconcilerRunOncePrunesThroughDesiredForLayersNotBareDesired(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	forcePivotNative(t)

	leaverDigest, survivorDigest := "d-leaver", "d-survivor"
	// Each module's OWN mount tree -- what captureLeaverInventories and
	// survivingLayerDirs inventory from.
	mkdirAll(t, filepath.Join(layout.ModuleMountPath(leaverDigest), "opt", "shared"))
	writeFile(t, filepath.Join(layout.ModuleMountPath(leaverDigest), "opt", "shared", "file.txt"), "leaver-tree-content")
	mkdirAll(t, filepath.Join(layout.ModuleMountPath(survivorDigest), "opt", "shared"))
	writeFile(t, filepath.Join(layout.ModuleMountPath(survivorDigest), "opt", "shared", "file.txt"), "survivor-content")
	// The LIVE ROOT's current copy of the shared path (as if hot-copied
	// from leaver on an earlier tick) -- what the prune actually acts on.
	mkdirAll(t, filepath.Join(layout.Root, "opt", "shared"))
	writeFile(t, filepath.Join(layout.Root, "opt", "shared", "file.txt"), "live-content")

	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "leaver", Digest: leaverDigest, Priority: 100},
			{ID: "survivor", Digest: survivorDigest, Priority: 200},
		},
		LastAttachedManifestHashes: map[string]string{
			"leaver":   testAttachStamp("leaver", nil),
			"survivor": testAttachStamp("survivor", nil),
		},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	client := &stubModulesClient{
		responses: map[string]string{
			// leaver is genuinely gone -- absent from the list entirely.
			// survivor is still assigned, but its manifest fetch 502s,
			// every tick, and it has no cache and no breadcrumb.
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"survivor", "name":"survivor", "priority":200, "effective_priority":200, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/survivor": `{"success":false,"error":"boom"}`,
		},
		statuses: map[string]int{
			"/api/v1/system/node_api/modules/survivor": 502,
		},
	}
	runner := &mount.RecorderRunner{}

	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
		// Not self-hosted: survivor's only protection from detach is
		// filterUnverifiedDetaches (manifestFetchFailed), not the
		// self-host guard -- isolating exactly the wiring this test pins.
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}

	// Tick 1: leaver detaches for real (captured + unarmed pending-prune
	// record written); survivor is deferred (fetch failed), unresolved, and
	// carried into desiredForLayers.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce (tick 1): %v", err)
	}
	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState after tick 1: %v", err)
	}
	attached := map[string]bool{}
	for _, m := range state.AttachedModules {
		attached[m.ID] = true
	}
	if attached["leaver"] {
		t.Fatalf("precondition failed: leaver must be detached after tick 1, got %+v", state.AttachedModules)
	}
	if !attached["survivor"] {
		t.Fatalf("precondition failed: survivor must remain attached (deferred, not detached) after tick 1, got %+v", state.AttachedModules)
	}

	// Tick 2: the record is now armed; this pass executes it. survivor is
	// STILL unresolved (same 502), so this is exactly the case that only
	// desiredForLayers (not bare desired, which would be empty) can carry
	// survivor into survivingLayerDirs.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce (tick 2): %v", err)
	}

	got, err := os.ReadFile(filepath.Join(layout.Root, "opt", "shared", "file.txt"))
	if err != nil {
		t.Fatalf("expected the shared path to survive (restored from survivor's tree), got error: %v", err)
	}
	if string(got) != "survivor-content" {
		t.Errorf("expected the shared path restored from survivor's tree, got %q — this is exactly what fails if hotReconcileIfNeeded/processPendingPrunes revert to passing bare `desired`", got)
	}
}
