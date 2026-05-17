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
type stubPuller struct {
	mu       sync.Mutex
	calls    []string
	cacheDir string
}

func (s *stubPuller) Pull(ref *oci.ModuleArtifactRef) (string, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, ref.ModuleID)
	cfs := filepath.Join(s.cacheDir, ref.Digest+".cfs")
	bundle := filepath.Join(s.cacheDir, ref.Digest+".cosign-bundle")
	return cfs, bundle, nil
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
	puller := &stubPuller{cacheDir: tmpRoot}
	runner := &mount.RecorderRunner{}

	cfg := ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         puller,
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		StatePath:      statePath,
	}
	r, err := NewReconciler(cfg)
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// Puller called for m1.
	if len(puller.calls) != 1 || puller.calls[0] != "m1" {
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

	// Pre-seed state with m1 already attached.
	mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m1", Digest: "abc123", Priority: 100},
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
