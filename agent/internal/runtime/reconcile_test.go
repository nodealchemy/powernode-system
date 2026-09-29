package runtime

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// testAttachStamp mirrors Reconciler.attachStamp for fixtures that seed a
// "this module is already in sync" stamp (IMP-01a05efa, IMP-f5c0afa7183a).
// Computed the same way production computes it — rendered unit bodies, the
// rendered security policy for a manifest with no security: block (all four
// callers below construct a services-only manifest — two pass a real
// services slice, two pass nil for a service-less fixture), and the agent
// version, empty in tests — rather than restating a literal, so a fixture
// cannot claim in-sync with a value the gate would never produce.
func testAttachStamp(moduleID string, services []manifest.Service) string {
	mf := &manifest.Manifest{Services: services}
	policy := buildPolicy(mf)
	hasUnits := len(mf.UnitNames()) > 0
	return lifecycle.RenderedServicesHash(moduleID, services, pivotAwareRootMode()) +
		"|" + security.RenderedPolicyHash(policy, hasUnits) + "|"
}

var (
	osMkdirAll  = os.MkdirAll
	osWriteFile = os.WriteFile
)

// versionBumpFixture is a stubModulesClient response body for a single
// module "m1" at the given digest — relocated here (round 9) from the
// now-deleted detach-before-attach test files so the surviving
// security_fail_closed_* fixtures that still use it keep working
// unchanged.
func versionBumpFixture(digest string) string {
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"%s",
			"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
			"services": [
				{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}
			]
		}
	}`, digest)
}

// versionBumpReconciler builds a Reconciler wired to a stubModulesClient and
// a RecorderRunner for a single-module version-bump scenario — relocated
// here (round 9) from the now-deleted detach-before-attach test files; the
// round-9 in-place-upgrade tests need the identical fixture shape.
func versionBumpReconciler(t *testing.T, tmpRoot, statePath string, client *stubModulesClient, runner *mount.RecorderRunner) *Reconciler {
	t.Helper()
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
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
	// M6 (review round 9): NewReconciler defaults UpgradeSettleWindow to a
	// real multi-second wait; every bump-exercising test in this package
	// (and its shared fixtures, e.g. security_fail_closed_*) goes through
	// this constructor, so a real wait here would slow the whole suite for
	// no benefit — the settle CHECK itself still always runs regardless of
	// this value (see UpgradeSettleWindow's own doc).
	r.cfg.UpgradeSettleWindow = 0
	return r
}

// bumpModuleDigest updates the stub manifest response for moduleID AND
// DELETES the on-disk manifest cache LoadOrFetch wrote for the OLD digest —
// NewReconciler defaults ManifestTTL to 90s (not 0: a corrected claim, this
// comment previously said the opposite), so without evicting the cache the
// next RunOnce pass would keep reading the OLD digest from disk (still
// fresh) and never observe the bump at all.
//
// round 9 CAVEAT, discovered writing upgrade_test.go: deleting the cache
// file destroys the OLD manifest's on-disk bytes BEFORE the next RunOnce
// call even starts, which is exactly what upgradeModule's
// reapplyOldPolicyBestEffort needs (via RunOnce's previousManifests
// snapshot, captured at the top of RunOnce from whatever LoadFromDisk
// currently returns) to restore the OLD digest's security policy on a
// refused bump. A test that needs reapplyOldPolicyBestEffort to see the
// real old manifest — i.e. anything asserting ON-DISK POLICY CONTENT after
// an upgradeModule refusal, not just "old stayed attached" — MUST use
// backdateManifestCache instead: it forces the same refetch by making the
// cache look stale (mtime), without deleting the file, so previousManifests
// still reads real old content when RunOnce takes its snapshot BEFORE this
// tick's own fetch loop overwrites it. This function remains correct for
// every OTHER use (any test that doesn't inspect post-refusal policy
// content) — see upgrade_test.go's own reconciler fixtures for the pattern.
func bumpModuleDigest(t *testing.T, manifestRoot, moduleID string, client *stubModulesClient, newDigest string) {
	t.Helper()
	client.responses["/api/v1/system/node_api/modules/"+moduleID] = versionBumpFixture(newDigest)
	if err := os.RemoveAll(filepath.Join(manifestRoot, moduleID)); err != nil {
		t.Fatal(err)
	}
}

func hasSystemctlOp(invocations []mount.Invocation, op, unit string) bool {
	for _, inv := range invocations {
		if inv.Name == "systemctl" && inv.Op == "Run" && containsArg(inv.Args, op) && containsArg(inv.Args, unit) {
			return true
		}
	}
	return false
}

func attachedDigest(t *testing.T, statePath, moduleID string) (digest string, ok bool) {
	t.Helper()
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == moduleID {
			return m.Digest, true
		}
	}
	return "", false
}

// pendingDigest reads moduleID's PendingDigest (N5/N2, review round 11) —
// mirrors attachedDigest's own shape for state.json's OTHER upgrade-in-
// flight field.
func pendingDigest(t *testing.T, statePath, moduleID string) (pending string, ok bool) {
	t.Helper()
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == moduleID {
			return m.PendingDigest, true
		}
	}
	return "", false
}

// backdateManifestCache pushes the on-disk manifest cache's mtime into the
// past so NewReconciler's default ManifestTTL treats it as stale on the
// next pass, WITHOUT deleting the file — relocated here (round 9) from the
// now-deleted version-bump rollback test file. Still needed by the
// security_fail_closed_partial_view fixtures, which rely on a STALE (not
// absent) cache entry to exercise the partial-view fallback path.
func backdateManifestCache(t *testing.T, manifestRoot, moduleID string) {
	t.Helper()
	path := filepath.Join(manifestRoot, moduleID, "manifest.json")
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("backdateManifestCache: %v", err)
	}
}

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
			"m1": testAttachStamp("m1", seedManifest.Services),
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
	freshHash := testAttachStamp("m1", []manifest.Service{
		{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always"},
	})
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
			// A NON-empty list that omits m1 → m1 is unassigned and should be
			// detached. (An entirely empty list is not read as an unassignment
			// — see TestRunOnce_EmptyAssignmentListRetainsEveryAttachedModule.)
			"/api/v1/system/node_api/modules": `{"success": true, "data": {"modules": [
				{"id":"cfg", "name":"cfg", "priority":100, "effective_priority":100, "has_data_file":false}
			]}}`,
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
// blob before EVER touching the unit that answers this node's own
// FetchAssignedModules calls (round 9: upgradeModule never stops the old
// unit at all for a successful in-place upgrade — it restarts it once the
// new digest's own artifact/policy/files are already in place). If this
// test fails after a refactor, the reconcile has regressed into fetching a
// self-hosted module's replacement content through a service the SAME
// tick has already disrupted — an unrecoverable circular dependency on a
// self-hosted platform.
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
	// M6 (review round 9): no real settle wait in tests, and the settled
	// unit must read `active` for the upgrade to actually commit — a bare
	// RecorderRunner defaults every is-active query to "not active".
	r.cfg.UpgradeSettleWindow = 0
	runner.StubOutput = map[string][]byte{"systemctl is-active powernode-hub-rails.service": []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	pullIdx, firstUnitActionIdx := -1, -1
	stopSeen := false
	for i, inv := range runner.Invocations {
		if inv.Name == "PULL" && len(inv.Args) >= 2 && inv.Args[1] == "new-digest" && pullIdx == -1 {
			pullIdx = i
		}
		if inv.Name == "systemctl" && len(inv.Args) >= 2 && inv.Args[1] == "powernode-hub-rails.service" {
			if firstUnitActionIdx == -1 {
				firstUnitActionIdx = i
			}
			if inv.Args[0] == "stop" {
				stopSeen = true
			}
		}
	}
	if pullIdx == -1 {
		t.Fatalf("expected a PULL for the new digest, got: %v", runner.Invocations)
	}
	if firstUnitActionIdx == -1 {
		t.Fatalf("expected at least one systemctl action naming the unit, got: %v", runner.Invocations)
	}
	if pullIdx > firstUnitActionIdx {
		t.Errorf("new artifact must be pulled BEFORE the unit is touched at all — pull at index %d, first unit action at index %d: %v",
			pullIdx, firstUnitActionIdx, runner.Invocations)
	}
	// round 9: a SUCCESSFUL in-place upgrade never stops the unit at all —
	// it restarts (or starts, if not yet active) once the new digest's own
	// artifact/policy/files are already in place. A stop appearing here
	// would mean the upgrade regressed back into detach-then-attach.
	if stopSeen {
		t.Errorf("round 9 REGRESSION: a successful in-place upgrade must never stop the unit, got: %v", runner.Invocations)
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
	orig, origChecked := pivotAwareRootMode, pivotAwareRootModeChecked
	pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeNative }
	pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return lifecycle.RootModeNative, nil }
	t.Cleanup(func() { pivotAwareRootMode, pivotAwareRootModeChecked = orig, origChecked })
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
	// A stamp the gate would actually PRODUCE for this module's (empty)
	// service set, so m1 is in toAttach on its digest change alone. Seeding a
	// literal manifest hash here instead put m1 in toReattach as well, and the
	// documented consequence (see the `unmaterialized` comment in RunOnce) is
	// that hotReconcileIfNeeded refuses it TWICE — which is a real property of
	// a same-tick digest+services change, not what this example is about.
	emptyHash := testAttachStamp("m1", nil)
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
	// M6 (review round 9): no real settle wait — this fixture's manifest
	// declares no services, so the settle CHECK has nothing to iterate,
	// but the WAIT itself still runs for whatever NewReconciler defaults to.
	r.cfg.UpgradeSettleWindow = 0
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

	emptyHash := testAttachStamp("m1", nil)
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
	// M6 (review round 9): no real settle wait — see the sibling test's own
	// comment for why (empty services block, only the wait itself matters).
	r.cfg.UpgradeSettleWindow = 0
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
	scriptPath := filepath.Join(t.TempDir(), "egress.nft")
	t.Cleanup(security.SetEgressScriptPathForTest(scriptPath))

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

	// IMP-13645c4df90a atomic rebuild: the whole egress ruleset is now ONE
	// `nft -f <script>` transaction, so there is exactly one nft invocation
	// per RunOnce tick — never a per-module "add chain" race, and never
	// `delete chain`.
	var nftCalls []mount.Invocation
	for _, inv := range runner.Invocations {
		if inv.Name == "nft" {
			nftCalls = append(nftCalls, inv)
		}
	}
	if len(nftCalls) != 1 {
		t.Fatalf("expected exactly one nft invocation for the whole tick (one unioned atomic apply), got %d: %+v", len(nftCalls), nftCalls)
	}
	if len(nftCalls[0].Args) < 1 || nftCalls[0].Args[0] != "-f" {
		t.Fatalf("expected the one nft invocation to be `-f <path>`, got %v", nftCalls[0].Args)
	}
	for _, a := range nftCalls[0].Args {
		if a == "delete" {
			t.Fatalf("must never `delete chain`: %v", nftCalls[0].Args)
		}
	}

	// The rendered script must contain the wildcard exactly once — proving
	// the permissive module's policy is what's actually enforced (not
	// clobbered by the restrictive sibling), and that this is one unioned
	// apply, not two competing per-module chain replacements.
	body, err := os.ReadFile(security.EgressStagingPathForTest())
	if err != nil {
		t.Fatalf("read rendered egress script: %v", err)
	}
	script := string(body)
	if !strings.Contains(script, "0.0.0.0/0") {
		t.Errorf("expected the effective egress chain to allow 0.0.0.0/0 (dev-cell's declared policy must survive claude-tmux's restrictive sibling); script:\n%s", script)
	}
	chainAdds := strings.Count(script, "add chain inet powernode_module_egress")
	if chainAdds != 1 {
		t.Errorf("expected exactly ONE egress chain statement across both modules attaching together, got %d; script:\n%s", chainAdds, script)
	}
}

// TestReconcilerRunOnce_SdwanExtrasSurviveAlongsideModuleEgressAllow —
// IMP-13645c4df90a. The node-wide default-deny egress chain was dropping the
// WireGuard handshake outright whenever ANY module declared egress_allow
// (verified live on VMs 9005/9007). ExtraEgress must apply whenever
// enforcement is on, alongside — not instead of — the module's own policy.
func TestReconcilerRunOnce_SdwanExtrasSurviveAlongsideModuleEgressAllow(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	scriptPath := filepath.Join(t.TempDir(), "egress.nft")
	t.Cleanup(security.SetEgressScriptPathForTest(scriptPath))

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
				"data": {"id":"m1", "name":"claude-tmux", "digest":"digm1",
				         "priority":100, "effective_priority":100,
				         "config": {"security": {"egress_allow": ["198.51.100.5:443"]}},
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
		ExtraEgress: func() security.EgressExtras {
			return security.EgressExtras{Networks: []security.EgressNetwork{{
				Interface:  "wg-sdwan-a1b2c3",
				ListenPort: 51820,
				AllowedIPs: []string{"fd00:1::/64"},
			}}}
		},
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// IMP-13645c4df90a atomic rebuild: exactly one nft invocation for the
	// whole tick — assert on the rendered script it staged, not per-rule argv.
	nftCount := 0
	for _, inv := range runner.Invocations {
		if inv.Name == "nft" {
			nftCount++
		}
	}
	if nftCount != 1 {
		t.Fatalf("expected exactly one nft invocation for the whole tick, got %d: %+v", nftCount, runner.Invocations)
	}
	body, err := os.ReadFile(security.EgressStagingPathForTest())
	if err != nil {
		t.Fatalf("read rendered egress script: %v", err)
	}
	script := string(body)
	if !strings.Contains(script, "daddr 198.51.100.5 tcp dport 443 accept") {
		t.Errorf("expected the module's own egress_allow rule to still be applied; script:\n%s", script)
	}
	if !strings.Contains(script, "udp sport 51820 accept") {
		t.Errorf("expected a udp sport accept rule for the SDWAN network's listen port alongside the module's own policy; script:\n%s", script)
	}
	if !strings.Contains(script, `oifname "wg-sdwan-a1b2c3" ip6 daddr { fd00:1::/64, } accept`) {
		t.Errorf("expected a scoped oifname+daddr-set accept rule for the SDWAN network's AllowedIPs alongside the module's own policy; script:\n%s", script)
	}
}

// TestNewReconcilerForCLI_SetsSkipEgress pins the wiring IMP-13645c4df90a
// review round item 2 depends on: every CLI-built reconciler (update, sync,
// attach, detach) must carry SkipEgress: true, since only the long-running
// service has live SDWAN extras to hand ApplyEgressAllowlistWithExtras.
func TestNewReconcilerForCLI_SetsSkipEgress(t *testing.T) {
	tmpRoot := t.TempDir()
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{"success": true, "data": {"modules": []}}`,
	}}

	r, err := NewReconcilerForCLI(FactoryConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    &mount.RecorderRunner{},
		Layout:         layout,
		StatePath:      filepath.Join(tmpRoot, "state.json"),
	})
	if err != nil {
		t.Fatalf("NewReconcilerForCLI: %v", err)
	}
	if !r.cfg.SkipEgress {
		t.Error("expected NewReconcilerForCLI to set SkipEgress: true")
	}
}

// TestReconcilerRunOnce_SkipEgressLeavesTheChainUntouched — IMP-13645c4df90a
// review round item 2. A module declares egress_allow (would normally
// enforce a chain), but SkipEgress is set (as NewReconcilerForCLI always
// sets it): RunOnce must never call nft at all, must log the skip via
// OnError, and must still succeed overall (identity/sudoers are unaffected).
func TestReconcilerRunOnce_SkipEgressLeavesTheChainUntouched(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	t.Cleanup(security.SetEgressScriptPathForTest(filepath.Join(t.TempDir(), "egress.nft")))

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
				"data": {"id":"m1", "name":"claude-tmux", "digest":"digm1",
				         "priority":100, "effective_priority":100,
				         "config": {"security": {"egress_allow": ["198.51.100.5:443"]}},
				         "services": [{"name":"claude", "start_command":"/usr/bin/claude", "restart_policy":"always"}]}
			}`,
		},
	}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &stubPuller{cacheDir: layout.ModulesCacheRoot}
	runner := &mount.RecorderRunner{}

	var skips []string
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
		SkipEgress:     true,
		OnError: func(stage string, err error) {
			skips = append(skips, stage+": "+err.Error())
		},
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	for _, inv := range runner.Invocations {
		if inv.Name == "nft" {
			t.Fatalf("SkipEgress must leave the chain untouched — no nft call was expected, got %+v", inv)
		}
	}
	found := false
	for _, s := range skips {
		if strings.HasPrefix(s, "reconciler:egress_skipped:") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected an OnError(\"reconciler:egress_skipped\", ...) call, got signals: %v", skips)
	}
}
