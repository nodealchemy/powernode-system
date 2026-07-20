package runtime

import (
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

var (
	osMkdirAll  = os.MkdirAll
	osWriteFile = os.WriteFile
)

// stubModulesClient implements ModulesClient + manifest.Client. Returns
// canned responses based on the request path.
type stubModulesClient struct {
	responses map[string]string // path → JSON body
	statuses  map[string]int    // path → HTTP status
	mu        sync.Mutex
	requests  []string
}

func (s *stubModulesClient) GetJSON(path string) (*http.Response, error) {
	s.mu.Lock()
	s.requests = append(s.requests, path)
	body := s.responses[path]
	status := s.statuses[path]
	s.mu.Unlock()
	if status == 0 {
		status = http.StatusOK
	}
	if body == "" {
		return &http.Response{StatusCode: 404, Body: io.NopCloser(strings.NewReader(""))}, nil
	}
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
	}, nil
}

// stubPuller pretends to pull modules without touching the network.
// Mimics the real *oci.Puller: writes an empty placeholder blob at
// the layout-derived cache path so the subsequent MountModule call
// finds something to loop-mount. Tests that don't exercise the
// attach path can leave cacheDir empty and skip the file write.
type stubPuller struct {
	mu       sync.Mutex
	calls    []string
	cacheDir string // typically Layout.ModulesCacheRoot
}

func (s *stubPuller) Pull(ref *oci.ModuleArtifactRef) (string, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, ref.ModuleID)
	// Mirror the real puller's filename convention exactly: prefix
	// `sha256_` (the mount-side `sanitizeDigest` does this), `.erofs`
	// extension. Tests that pass bare-hex digests get the bare hex
	// straight through (no colons to substitute).
	digestFs := strings.ReplaceAll(strings.ReplaceAll(ref.Digest, ":", "_"), "/", "_")
	erofsPath := filepath.Join(s.cacheDir, digestFs+".erofs")
	bundlePath := filepath.Join(s.cacheDir, digestFs+".cosign-bundle")
	if s.cacheDir != "" {
		_ = osMkdirAll(s.cacheDir, 0o755)
		_ = osWriteFile(erofsPath, []byte("stub-erofs-blob"), 0o644)
	}
	return erofsPath, bundlePath, nil
}

func TestReconcilerRunOnceAttachesNewModule(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	// P8.1: route lifecycle unit-file writes into a tmpdir so we don't
	// touch the host's /etc/systemd/system.
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

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
				"data": {
					"id":"m1", "name":"nginx",
					"priority":100, "effective_priority":100,
					"digest":"abc123",
					"services": [
						{"name":"nginx", "start_command":"/usr/sbin/nginx -g 'daemon off;'", "restart_policy":"always"}
					]
				}
			}`,
		},
	}
	// Layout rooted under tmpRoot so the reconciler's MountModule
	// (which calls layout.ModuleCachePath) looks for the staged blob
	// inside tmpRoot, not /persist/cache/modules. stubPuller writes
	// the placeholder blob at the same path.
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	cfg := ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
	}
	r, err := NewReconciler(cfg)
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// Puller called for m1 twice — once by prefetchNewArtifacts (ahead of
	// any detach, see its doc comment) and once by the normal attachModule
	// call later in the same tick. The second call is a cheap no-op
	// (MountModule is content-addressed-by-digest idempotent), not a
	// wasted fetch.
	if len(puller.calls) != 2 || puller.calls[0] != "m1" || puller.calls[1] != "m1" {
		t.Errorf("puller calls: %v", puller.calls)
	}

	// P8.1: systemctl start of the service's generated unit name.
	foundStart := false
	for _, inv := range runner.Invocations {
		if inv.Name == "systemctl" && inv.Op == "Run" &&
			len(inv.Args) >= 2 && inv.Args[0] == "start" && inv.Args[1] == "powernode-m1-nginx.service" {
			foundStart = true
		}
	}
	if !foundStart {
		t.Errorf("expected `systemctl start powernode-m1-nginx.service`, got: %v", runner.Invocations)
	}

	// State persisted with m1 in attached modules.
	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if len(state.AttachedModules) != 1 || state.AttachedModules[0].ID != "m1" {
		t.Errorf("state.AttachedModules: %+v", state.AttachedModules)
	}
}

func TestReconcilerRunOnceNoOpsWhenStateMatches(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")

	// Pre-seed state with m1 already attached AND its manifest hash
	// already recorded — so the re-attach pass sees no drift and
	// skips the attachModule call. State persisted by older agents
	// (no LastAttachedManifestHashes field) will trigger ONE re-attach
	// per reconcile cycle until the hash is populated; that's the
	// intended upgrade behavior and covered by the manifest-change
	// re-attach test below.
	seedManifest := &manifest.Manifest{
		Services: []manifest.Service{
			{Name: "nginx", StartCommand: "/usr/sbin/nginx", RestartPolicy: "always"},
		},
	}
	mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m1", Digest: "abc123", Priority: 100},
		},
		LastAttachedManifestHashes: map[string]string{
			"m1": seedManifest.ServicesHash(),
		},
	})

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
				         "priority":100, "effective_priority":100,
				         "services": [{"name":"nginx", "start_command":"/usr/sbin/nginx", "restart_policy":"always"}]}
			}`,
		},
	}
	puller := &stubPuller{cacheDir: tmpRoot}
	runner := &mount.RecorderRunner{}

	r, _ := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
	})
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// No new pulls.
	if len(puller.calls) != 0 {
		t.Errorf("expected no pulls, got %v", puller.calls)
	}
	// No systemctl start (already attached).
	for _, inv := range runner.Invocations {
		if inv.Name == "systemctl" && len(inv.Args) > 0 && inv.Args[0] == "start" {
			t.Errorf("unexpected systemctl start: %v", inv)
		}
	}
}

// TestReconcilerRunOnceReattachesOnManifestChange exercises the gap
// that bit the 2026-05-25 qemu-guest-agent dogfood: an already-mounted
// module whose manifest gains new services must be re-attached so the
// new systemd unit lands at /etc/systemd/system. The fix is per-module
// SHA256 hashing of the services block in State.LastAttachedManifestHashes;
// when the fresh hash differs from the stored value, attachModule is
// re-invoked. See claude_code.agent_reattach_gap memory.
func TestReconcilerRunOnceReattachesOnManifestChange(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	// Pre-seed: m1 attached with an EMPTY services hash (simulating a
	// previously-published version whose manifest had no services, then
	// later the manifest grew a services entry without a digest bump).
	staleHash := (&manifest.Manifest{Services: []manifest.Service{}}).ServicesHash()
	mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m1", Digest: "abc123", Priority: 100},
		},
		LastAttachedManifestHashes: map[string]string{
			"m1": staleHash,
		},
	})

	// Platform now returns a manifest with one service. Hash should
	// differ from the stored staleHash → re-attach.
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
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	r, _ := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
	})
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// systemctl start of the newly-rendered qga unit confirms
	// AttachServices ran via the re-attach pass.
	foundStart := false
	for _, inv := range runner.Invocations {
		if inv.Name == "systemctl" && inv.Op == "Run" &&
			len(inv.Args) >= 2 && inv.Args[0] == "start" && inv.Args[1] == "powernode-m1-qga.service" {
			foundStart = true
		}
	}
	if !foundStart {
		t.Errorf("expected `systemctl start powernode-m1-qga.service` from re-attach, got: %v", runner.Invocations)
	}

	// State persists the fresh hash so subsequent ticks don't re-trigger.
	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	freshHash := (&manifest.Manifest{Services: []manifest.Service{
		{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always"},
	}}).ServicesHash()
	if state.LastAttachedManifestHashes["m1"] != freshHash {
		t.Errorf("expected stored hash to update to freshHash=%s, got %s",
			freshHash, state.LastAttachedManifestHashes["m1"])
	}
}

func TestReconcilerRunOnceDetachesRemovedModule(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")

	// Pre-seed with m1 attached but platform no longer assigns it.
	mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m1", Digest: "abc123", Priority: 100},
		},
	})

	manifestRoot := filepath.Join(tmpRoot, "manifests")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	// Pre-seed manifest cache so detach knows the services.
	dir := filepath.Join(manifestRoot, "m1")
	mkdirAll(t, dir)
	writeFile(t, filepath.Join(dir, "manifest.json"),
		`{"id":"m1","name":"nginx","services":[{"name":"nginx","start_command":"/usr/sbin/nginx"}]}`)

	client := &stubModulesClient{
		responses: map[string]string{
			// Empty modules list → m1 should be detached.
			"/api/v1/system/node_api/modules": `{"success": true, "data": {"modules": []}}`,
		},
	}
	runner := &mount.RecorderRunner{}

	r, _ := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
	})
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// P8.1: lifecycle.DetachServices issues stop on the generated unit name.
	foundStop := false
	for _, inv := range runner.Invocations {
		if inv.Name == "systemctl" && len(inv.Args) >= 2 &&
			inv.Args[0] == "stop" && inv.Args[1] == "powernode-m1-nginx.service" {
			foundStop = true
		}
	}
	if !foundStop {
		t.Errorf("expected `systemctl stop powernode-m1-nginx.service`, got: %v", runner.Invocations)
	}

	// State updated to no attached modules.
	state, _ := mount.LoadState(statePath)
	if len(state.AttachedModules) != 0 {
		t.Errorf("expected empty attached modules, got %+v", state.AttachedModules)
	}
}

// orderTrackingPuller mimics stubPuller but also records into the SAME
// mount.RecorderRunner.Invocations timeline as the systemd stop/start calls
// (via a synthetic "PULL" marker), so a test can assert relative ordering
// between "fetched the new module's blob" and "stopped the old module's
// service" — the exact interaction the circular-dependency bug depended on.
type orderTrackingPuller struct {
	cacheDir string
	runner   *mount.RecorderRunner
}

func (p *orderTrackingPuller) Pull(ref *oci.ModuleArtifactRef) (string, string, error) {
	p.runner.Invocations = append(p.runner.Invocations,
		mount.Invocation{Op: "Run", Name: "PULL", Args: []string{ref.ModuleID, ref.Digest}})
	digestFs := strings.ReplaceAll(strings.ReplaceAll(ref.Digest, ":", "_"), "/", "_")
	erofsPath := filepath.Join(p.cacheDir, digestFs+".erofs")
	bundlePath := filepath.Join(p.cacheDir, digestFs+".cosign-bundle")
	_ = osMkdirAll(p.cacheDir, 0o755)
	_ = osWriteFile(erofsPath, []byte("stub-erofs-blob"), 0o644)
	return erofsPath, bundlePath, nil
}

// TestReconcilerRunOnceFetchesNewArtifactBeforeDetachingOldService is the
// regression test for the 2026-07-20 ops-hub outage: a same-tick version
// bump (same module ID, old digest → new digest) must pull+mount the NEW
// blob before stopping the OLD service, never after. If this test fails
// after a refactor, the reconcile has regressed into fetching a self-hosted
// module's replacement content through a service the SAME tick just tore
// down — an unrecoverable circular dependency on a self-hosted platform.
func TestReconcilerRunOnceFetchesNewArtifactBeforeDetachingOldService(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	// Pre-seed: "hub" attached at the old digest.
	mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "hub", Digest: "old-digest", Priority: 100},
		},
	})
	manifestRoot := filepath.Join(tmpRoot, "manifests")

	// Platform now assigns "hub" at a NEW digest — a version bump, same
	// module ID, landing "hub"@old-digest in toDetach and "hub"@new-digest
	// in toAttach in the same RunOnce tick.
	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"hub", "name":"hub-backend", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/hub": `{
				"success": true,
				"data": {"id":"hub", "name":"hub-backend", "digest":"new-digest",
				         "priority":100, "effective_priority":100,
				         "services": [{"name":"rails", "start_command":"/usr/bin/rails-start", "restart_policy":"always"}]}
			}`,
		},
	}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	runner := &mount.RecorderRunner{}
	puller := &orderTrackingPuller{cacheDir: layout.ModulesCacheRoot, runner: runner}

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

	pullIdx, stopIdx := -1, -1
	for i, inv := range runner.Invocations {
		if inv.Name == "PULL" && len(inv.Args) >= 2 && inv.Args[1] == "new-digest" && pullIdx == -1 {
			pullIdx = i
		}
		if inv.Name == "systemctl" && len(inv.Args) >= 2 &&
			inv.Args[0] == "stop" && inv.Args[1] == "powernode-hub-rails.service" && stopIdx == -1 {
			stopIdx = i
		}
	}
	if pullIdx == -1 {
		t.Fatalf("expected a PULL for the new digest, got: %v", runner.Invocations)
	}
	if stopIdx == -1 {
		t.Fatalf("expected `systemctl stop powernode-hub-rails.service`, got: %v", runner.Invocations)
	}
	if pullIdx > stopIdx {
		t.Errorf("new artifact must be pulled BEFORE the old service is stopped — pull at index %d, stop at index %d: %v",
			pullIdx, stopIdx, runner.Invocations)
	}

	// Sanity: the new module actually ends up attached at the new digest.
	state, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if len(state.AttachedModules) != 1 || state.AttachedModules[0].Digest != "new-digest" {
		t.Errorf("expected hub@new-digest attached, got: %+v", state.AttachedModules)
	}
}

func TestReconcilerRequiredFields(t *testing.T) {
	cases := []struct {
		name string
		cfg  ReconcilerConfig
	}{
		{"missing ModulesClient", ReconcilerConfig{ManifestClient: &stubModulesClient{}, Puller: &stubPuller{}, Verifier: verify.AlwaysOK{}, MountRunner: &mount.RecorderRunner{}}},
		{"missing ManifestClient", ReconcilerConfig{ModulesClient: &stubModulesClient{}, Puller: &stubPuller{}, Verifier: verify.AlwaysOK{}, MountRunner: &mount.RecorderRunner{}}},
		{"missing Puller", ReconcilerConfig{ModulesClient: &stubModulesClient{}, ManifestClient: &stubModulesClient{}, Verifier: verify.AlwaysOK{}, MountRunner: &mount.RecorderRunner{}}},
		{"missing Verifier", ReconcilerConfig{ModulesClient: &stubModulesClient{}, ManifestClient: &stubModulesClient{}, Puller: &stubPuller{}, MountRunner: &mount.RecorderRunner{}}},
		{"missing MountRunner", ReconcilerConfig{ModulesClient: &stubModulesClient{}, ManifestClient: &stubModulesClient{}, Puller: &stubPuller{}, Verifier: verify.AlwaysOK{}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := NewReconciler(tc.cfg); err == nil {
				t.Errorf("expected error")
			}
		})
	}
}

func TestReconcilerDefaultsManifestTTL(t *testing.T) {
	// A zero ManifestTTL means "trust the on-disk manifest forever", which
	// pins the agent to a stale module digest — a rebuilt+republished module
	// is never re-pulled. NewReconciler must default it to a non-zero TTL so
	// the reconcile loop surfaces republished modules without a manual cache
	// clear.
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  &stubModulesClient{},
		ManifestClient: &stubModulesClient{},
		Puller:         &stubPuller{},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    &mount.RecorderRunner{},
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if r.cfg.ManifestTTL <= 0 {
		t.Fatalf("ManifestTTL defaulted to %v; want non-zero (cache-forever regression)", r.cfg.ManifestTTL)
	}
}

func TestReconcilerDryRunSkipsMutations(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")

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
				"data": {"id":"m1", "digest":"abc","priority":100,"effective_priority":100,
				         "services":[{"name":"nginx","start_command":"/usr/sbin/nginx"}]}
			}`,
		},
	}
	puller := &stubPuller{cacheDir: tmpRoot}
	runner := &mount.RecorderRunner{}

	r, _ := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
		DryRun:         true,
	})
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if len(puller.calls) != 0 {
		t.Errorf("dry-run should not pull: %v", puller.calls)
	}
	for _, inv := range runner.Invocations {
		if inv.Name == "systemctl" {
			t.Errorf("dry-run should not invoke systemctl: %v", inv)
		}
	}
}

func TestReconcilerSurfacesFetchError(t *testing.T) {
	tmpRoot := t.TempDir()
	client := &stubModulesClient{
		statuses:  map[string]int{"/api/v1/system/node_api/modules": 500},
		responses: map[string]string{"/api/v1/system/node_api/modules": `{"success":false,"error":"boom"}`},
	}
	r, _ := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		Puller:         &stubPuller{cacheDir: tmpRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    &mount.RecorderRunner{},
		StatePath:      filepath.Join(tmpRoot, "state.json"),
	})
	err := r.RunOnce(context.Background())
	if err == nil {
		t.Fatalf("expected error from 500 status")
	}
	if !strings.Contains(err.Error(), "fetch") {
		t.Errorf("expected fetch-error wrapping, got %v", err)
	}
}

func mkdirAll(t *testing.T, p string) {
	t.Helper()
	if err := osMkdirAll(p, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
}

func writeFile(t *testing.T, p, body string) {
	t.Helper()
	if err := osWriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
}

// forcePivotNative overrides the package-level pivotAwareRootMode
// indirection for the duration of the test, so RunOnce's hot-reconcile
// gate believes it's running on a pivot node without needing a real
// overlayfs root (lifecycle.PivotAwareRootMode's own root probe is
// unexported and keyed off the live process's actual "/" — not fakeable
// from this package).
func forcePivotNative(t *testing.T) {
	t.Helper()
	orig := pivotAwareRootMode
	pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeNative }
	t.Cleanup(func() { pivotAwareRootMode = orig })
}

// TestReconcilerHotReconcileSkipsFirstTickOnPivotNode covers the
// ComposeForPivot baseline gap: on a pivot node's very first reconcile
// tick there's no state.json yet, so every boot module looks like a fresh
// attach even though its files are ALREADY part of the boot union.
// hotReconcileIfNeeded must not hot-copy on that tick — doing so would be
// redundant at best (the file is already at the live root from boot).
func TestReconcilerHotReconcileSkipsFirstTickOnPivotNode(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json") // no pre-seed: this IS the no-state-yet first tick

	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"hub-frontend", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"hub-frontend", "digest":"d1",
				         "priority":100, "effective_priority":100,
				         "reboot_required": false,
				         "services": []}
			}`,
		},
	}
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	// Fake "already part of the boot union" content at the module's
	// mountpoint. RecorderRunner never actually issues the erofs loop
	// mount, so this stands in for what a real mount would have already
	// made visible pre-pivot.
	mountDir := layout.ModuleMountPath("d1")
	mkdirAll(t, filepath.Join(mountDir, "opt", "hub-frontend"))
	writeFile(t, filepath.Join(mountDir, "opt", "hub-frontend", "index.html"), "<html>boot</html>")

	forcePivotNative(t)

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

	if _, err := os.Stat(filepath.Join(layout.Root, "opt", "hub-frontend", "index.html")); !os.IsNotExist(err) {
		t.Errorf("expected NO hot-copy on the first (empty-state) tick, but found one (stat err=%v)", err)
	}
}

// TestReconcilerHotReconcileCopiesChangedModuleOnPivotNode covers the
// primary case this feature exists for: a SECOND tick (real prior state,
// so stateWasEmpty is false) where a module's digest changed. The new
// content — standing in for what a real erofs loop-mount would expose at
// the module's per-digest mountpoint — must land at the live root without
// a reboot.
func TestReconcilerHotReconcileCopiesChangedModuleOnPivotNode(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")

	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()

	// Pre-seed real prior state (module m1 already attached at d1, with
	// its (empty) services hash recorded) so this run is tick 2+, not the
	// empty-state baseline tick.
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
					{"id":"m1", "name":"hub-frontend", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"hub-frontend", "digest":"d2",
				         "priority":100, "effective_priority":100,
				         "reboot_required": false,
				         "services": []}
			}`,
		},
	}
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	newMountDir := layout.ModuleMountPath("d2")
	mkdirAll(t, filepath.Join(newMountDir, "opt", "hub-frontend"))
	writeFile(t, filepath.Join(newMountDir, "opt", "hub-frontend", "index.html"), "<html>v2</html>")

	forcePivotNative(t)

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

	got, err := os.ReadFile(filepath.Join(layout.Root, "opt", "hub-frontend", "index.html"))
	if err != nil {
		t.Fatalf("expected hot-copied file at the live root, got error: %v", err)
	}
	if string(got) != "<html>v2</html>" {
		t.Errorf("hot-copied content = %q, want %q", got, "<html>v2</html>")
	}
}

// TestReconcilerHotReconcileSkipsAndWarnsWhenRebootRequired covers the
// other half of the gate: a module that declares reboot_required: true
// (base-os-ubuntu-noble, post this change) must NOT be hot-copied — its
// changed content is left for the next reboot — and the reconciler must
// surface a "reboot pending" signal via OnError instead.
func TestReconcilerHotReconcileSkipsAndWarnsWhenRebootRequired(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")

	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()

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
					{"id":"m1", "name":"base-os", "priority":100, "effective_priority":100, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"base-os", "digest":"d2",
				         "priority":100, "effective_priority":100,
				         "reboot_required": true,
				         "services": []}
			}`,
		},
	}
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	newMountDir := layout.ModuleMountPath("d2")
	mkdirAll(t, filepath.Join(newMountDir, "etc"))
	writeFile(t, filepath.Join(newMountDir, "etc", "os-release"), "v2")

	forcePivotNative(t)

	var stages []string
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
		OnError: func(stage string, _ error) {
			stages = append(stages, stage)
		},
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if _, err := os.Stat(filepath.Join(layout.Root, "etc", "os-release")); !os.IsNotExist(err) {
		t.Errorf("reboot_required module must NOT be hot-copied, but found a copy (stat err=%v)", err)
	}

	found := 0
	for _, s := range stages {
		if s == "reconciler:reboot_pending" {
			found++
		}
	}
	if found != 1 {
		t.Errorf("expected exactly one reconciler:reboot_pending OnError, got %d (stages=%v)", found, stages)
	}
}

// TestReconcilerRunOnce_EgressUnionsAcrossModules_PermissiveSurvives is the
// end-to-end regression for the real dev-cell + claude-tmux bug: two
// modules attach in the SAME reconcile pass, one declaring a restrictive
// explicit-empty egress policy (claude-tmux's real manifest), the other an
// unrestricted wildcard (dev-cell's real manifest, "a dev-cell is by
// nature an unbounded egress sandbox"). Before the fix, ApplyEgressAllowlist
// ran per-module against one shared nftables chain, so whichever module's
// attachModule call happened to run LAST silently overwrote the other's
// policy — observed live as claude-tmux's restriction winning and dev-cell
// having no internet access despite its manifest explicitly asking for it.
// After the fix, egress is unioned once per RunOnce tick from every
// currently-desired module's declared policy, so the wildcard must survive
// regardless of attach order.
func TestReconcilerRunOnce_EgressUnionsAcrossModules_PermissiveSurvives(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{
		responses: map[string]string{
			"/api/v1/system/node_api/modules": `{
				"success": true,
				"data": {"modules": [
					{"id":"m1", "name":"claude-tmux", "priority":100, "effective_priority":100, "has_data_file":true},
					{"id":"m2", "name":"dev-cell", "priority":200, "effective_priority":200, "has_data_file":true}
				]}
			}`,
			"/api/v1/system/node_api/modules/m1": `{
				"success": true,
				"data": {"id":"m1", "name":"claude-tmux", "digest":"digm1",
				         "priority":100, "effective_priority":100,
				         "config": {"security": {"egress_allow": []}},
				         "services": [{"name":"claude", "start_command":"/usr/bin/claude", "restart_policy":"always"}]}
			}`,
			"/api/v1/system/node_api/modules/m2": `{
				"success": true,
				"data": {"id":"m2", "name":"dev-cell", "digest":"digm2",
				         "priority":200, "effective_priority":200,
				         "config": {"security": {"egress_allow": ["0.0.0.0/0"]}},
				         "services": [{"name":"executor", "start_command":"/usr/local/bin/dev-cell-executor.sh", "restart_policy":"always"}]}
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

	// The FINAL egress chain (last "nft add chain ... policy drop" plus
	// whatever rules follow it) must contain the wildcard — proving the
	// permissive module's policy is what's actually enforced, not
	// clobbered by the restrictive sibling.
	var lastChainAt = -1
	for i, inv := range runner.Invocations {
		if inv.Name == "nft" && len(inv.Args) >= 3 && inv.Args[0] == "add" && inv.Args[1] == "chain" {
			lastChainAt = i
		}
	}
	if lastChainAt < 0 {
		t.Fatalf("expected at least one `nft add chain` invocation; got %+v", runner.Invocations)
	}
	foundWildcard := false
	for _, inv := range runner.Invocations[lastChainAt:] {
		if inv.Name != "nft" {
			continue
		}
		for _, a := range inv.Args {
			if a == "0.0.0.0/0" {
				foundWildcard = true
			}
		}
	}
	if !foundWildcard {
		t.Errorf("expected the effective egress chain to allow 0.0.0.0/0 (dev-cell's declared policy must survive claude-tmux's restrictive sibling); got: %+v", runner.Invocations)
	}

	// And there must be only ONE "add chain ... policy drop" for the
	// egress table across the whole run — proving this is a single unioned
	// apply, not two competing per-module chain replacements.
	chainAdds := 0
	for _, inv := range runner.Invocations {
		if inv.Name == "nft" && len(inv.Args) >= 3 && inv.Args[0] == "add" && inv.Args[1] == "chain" {
			joined := strings.Join(inv.Args, " ")
			if strings.Contains(joined, "powernode_module_egress") {
				chainAdds++
			}
		}
	}
	if chainAdds != 1 {
		t.Errorf("expected exactly ONE egress chain install across both modules attaching together, got %d; invocations: %+v", chainAdds, runner.Invocations)
	}
}
