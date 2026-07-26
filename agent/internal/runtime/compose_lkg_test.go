package runtime

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// lkgTestEnv redirects the boot-LKG package paths + fetch-retry knobs to a temp
// sandbox and returns a restore func. No t.Parallel with these (shared vars).
func lkgTestEnv(t *testing.T) (dir string, restore func()) {
	t.Helper()
	dir = t.TempDir()
	// PendingComposePath too: resolveComposeSet now CLEARS the staged file on a
	// successful live fetch and READS it on a failed one, so a test that does not
	// redirect it mutates the host's real /persist state.
	origLKG, origBC, origSentinel := BootLKGPath, BootBreadcrumbPath, LKGDisableSentinel
	origPending := PendingComposePath
	PendingComposePath = filepath.Join(dir, "pending-compose.json")
	origAttempts, origBackoff, origCmdline := lkgFetchAttempts, lkgFetchBackoff, procCmdlinePath
	BootLKGPath = filepath.Join(dir, "assignment-lkg.json")
	BootBreadcrumbPath = filepath.Join(dir, "boot-composed.json")
	LKGDisableSentinel = filepath.Join(dir, "lkg-fallback.disabled")
	lkgFetchAttempts = 1
	lkgFetchBackoff = 0
	procCmdlinePath = filepath.Join(dir, "cmdline")
	_ = os.WriteFile(procCmdlinePath, []byte("ro quiet\n"), 0o644)
	return dir, func() {
		BootLKGPath, BootBreadcrumbPath, LKGDisableSentinel = origLKG, origBC, origSentinel
		PendingComposePath = origPending
		lkgFetchAttempts, lkgFetchBackoff, procCmdlinePath = origAttempts, origBackoff, origCmdline
	}
}

// failingFetchReconciler builds a reconciler whose module fetch always fails
// (unknown path → 404), with a tmp-rooted layout for blob-cache lookups.
func failingFetchReconciler(t *testing.T, dir string) (*Reconciler, mount.Layout) {
	t.Helper()
	layout := mount.DefaultLayout()
	layout.Root = dir
	layout = layout.Resolve()
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  &stubModulesClient{}, // no responses → 404 → fetch error
		ManifestClient: &stubModulesClient{},
		Puller:         &stubPuller{},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    &mount.RecorderRunner{},
		Layout:         layout,
		PlatformURL:    "https://dev.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	return r, layout
}

// stageValidLKGAt writes a valid one-data-module LKG at BootLKGPath with its
// blob staged in the layout's digest-keyed cache.
func stageValidLKGAt(t *testing.T, layout mount.Layout) {
	t.Helper()
	digest := "sha256:abc123"
	blob := layout.ModuleCachePath(digest)
	if err := os.MkdirAll(filepath.Dir(blob), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(blob, []byte("stub"), 0o644); err != nil {
		t.Fatal(err)
	}
	mfRaw, _ := json.Marshal(map[string]any{"id": "m1", "digest": digest, "effective_priority": 100})
	lkg := &BootLKG{
		ConfirmedAt: time.Now().UTC().Add(-time.Hour),
		Source:      "https://dev.example.test",
		Hostname:    "ops-hub",
		Modules:     []LKGModule{{ID: "m1", HasDataFile: true, EffectivePriority: 100, Digest: digest, Manifest: mfRaw}},
	}
	if err := WriteBootLKG(BootLKGPath, lkg); err != nil {
		t.Fatal(err)
	}
}

func TestResolveComposeSet_LiveFail_FallsBackToValidLKG(t *testing.T) {
	dir, restore := lkgTestEnv(t)
	defer restore()
	r, layout := failingFetchReconciler(t, dir)
	stageValidLKGAt(t, layout)

	desired, manifests, bc, err := r.resolveComposeSet(context.Background())
	if err != nil {
		t.Fatalf("expected fallback success, got %v", err)
	}
	if len(desired) != 1 || desired[0].ID != "m1" {
		t.Fatalf("desired from LKG mismatch: %+v", desired)
	}
	if _, ok := manifests["m1"]; !ok {
		t.Fatal("manifest for m1 missing from fallback compose inputs")
	}
	if bc == nil || !bc.FromLKG {
		t.Fatalf("breadcrumb must record FromLKG=true on a fallback boot: %+v", bc)
	}
}

func TestResolveComposeSet_LiveFail_KillSwitchSentinel_Errors(t *testing.T) {
	dir, restore := lkgTestEnv(t)
	defer restore()
	r, layout := failingFetchReconciler(t, dir)
	stageValidLKGAt(t, layout)
	// Disable the fallback: even with a perfectly valid LKG present, the boot
	// must surface the fetch error (revert to live-only behavior).
	if err := os.WriteFile(LKGDisableSentinel, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := r.resolveComposeSet(context.Background()); err == nil {
		t.Fatal("kill-switch sentinel present → resolveComposeSet must error, not fall back")
	}
}

func TestResolveComposeSet_LiveFail_InvalidLKG_FailsLoud(t *testing.T) {
	dir, restore := lkgTestEnv(t)
	defer restore()
	r, layout := failingFetchReconciler(t, dir)
	stageValidLKGAt(t, layout)
	// Remove the staged blob → the LKG is now internally inconsistent; the
	// fallback must fail LOUD rather than compose a root that can't mount.
	if err := os.Remove(layout.ModuleCachePath("sha256:abc123")); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := r.resolveComposeSet(context.Background()); err == nil {
		t.Fatal("invalid LKG (missing blob) → resolveComposeSet must fail loud")
	}
}

func TestResolveComposeSet_LiveFail_NoLKG_Errors(t *testing.T) {
	dir, restore := lkgTestEnv(t)
	defer restore()
	r, _ := failingFetchReconciler(t, dir)
	// No LKG file at all.
	if _, _, _, err := r.resolveComposeSet(context.Background()); err == nil {
		t.Fatal("fetch failed AND no boot-LKG → must error")
	}
}

func TestResolveComposeSet_LiveSuccess_BreadcrumbNotFromLKG(t *testing.T) {
	dir, restore := lkgTestEnv(t)
	defer restore()
	layout := mount.DefaultLayout()
	layout.Root = dir
	layout = layout.Resolve()
	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{"success":true,"data":{"modules":[
				{"id":"m1","name":"hub-backend","priority":100,"effective_priority":100,"has_data_file":true}
			],"hostname":"ops-hub","lkg_staleness_threshold_seconds":600}}`,
			"/api/v1/system/node_api/modules/m1": `{"success":true,"data":{
				"id":"m1","name":"hub-backend","effective_priority":100,"digest":"sha256:live1",
				"services":[{"name":"web","start_command":"/x","restart_policy":"always"}]}}`,
		},
	}
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(dir, "manifests"),
		Puller:         &stubPuller{},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    &mount.RecorderRunner{},
		Layout:         layout,
		PlatformURL:    "https://dev.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	desired, _, bc, err := r.resolveComposeSet(context.Background())
	if err != nil {
		t.Fatalf("live success expected, got %v", err)
	}
	if len(desired) != 1 || desired[0].Digest != "sha256:live1" {
		t.Fatalf("desired from live fetch mismatch: %+v", desired)
	}
	if bc == nil || bc.FromLKG {
		t.Fatalf("live boot breadcrumb must have FromLKG=false: %+v", bc)
	}
	if bc.StalenessThresholdSeconds != 600 {
		t.Fatalf("breadcrumb must carry backend-delivered staleness threshold; got %d", bc.StalenessThresholdSeconds)
	}
	if len(bc.Modules) != 1 || len(bc.Modules[0].Manifest) == 0 {
		t.Fatalf("live breadcrumb must embed the resolved manifest: %+v", bc.Modules)
	}
	if bc.Incomplete {
		t.Fatal("a fully-composed set must not be marked incomplete")
	}
}

// MED-4: when the platform assigns 2 data modules but one's manifest can't be
// resolved, the node still boots on the rest, but the breadcrumb is marked
// INCOMPLETE so the capturer never freezes the degraded set as last-known-good.
func TestResolveComposeSet_LiveSuccess_MarksIncompleteWhenDataModuleDropped(t *testing.T) {
	dir, restore := lkgTestEnv(t)
	defer restore()
	layout := mount.DefaultLayout()
	layout.Root = dir
	layout = layout.Resolve()
	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{"success":true,"data":{"modules":[
				{"id":"m1","name":"hub-backend","effective_priority":100,"has_data_file":true},
				{"id":"m2","name":"other","effective_priority":50,"has_data_file":true}
			]}}`,
			"/api/v1/system/node_api/modules/m1": `{"success":true,"data":{"id":"m1","effective_priority":100,"digest":"sha256:m1"}}`,
			// m2's manifest is deliberately absent → 404 → dropped at compose.
		},
	}
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient: client, ManifestClient: client, ManifestRoot: filepath.Join(dir, "manifests"),
		Puller: &stubPuller{}, Verifier: verify.AlwaysOK{}, MountRunner: &mount.RecorderRunner{},
		Layout: layout, PlatformURL: "https://dev.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	desired, _, bc, err := r.resolveComposeSet(context.Background())
	if err != nil {
		t.Fatalf("node should still compose on the surviving module: %v", err)
	}
	if len(desired) != 1 || desired[0].ID != "m1" {
		t.Fatalf("expected only m1 composed: %+v", desired)
	}
	if !bc.Incomplete {
		t.Fatal("breadcrumb must be marked incomplete when an assigned data module was dropped")
	}
}
