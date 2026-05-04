package k3sd

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/powernode/platform/extensions/system/agent/internal/transport"
)

// stubServerApplier is the in-memory ServerApplier used by all
// state-machine tests. Records every call so assertions can verify
// both ordering and idempotency.
type stubServerApplier struct {
	mu sync.Mutex

	Installed         bool
	Running           bool
	Version_          string
	BootstrapState    BootstrapState
	BootstrapStateErr error
	InstallErr        error
	StartErr          error

	HasInstalledCalls int
	InstallCalls      int
	IsRunningCalls    int
	StartCalls        int
	StopCalls         int
	VersionCalls      int
	CaptureCalls      int
	CleanupCalls      int
}

func (s *stubServerApplier) HasInstalled(_ context.Context) (bool, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.HasInstalledCalls++
	return s.Installed, nil
}
func (s *stubServerApplier) InstallK3sServer(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.InstallCalls++
	if s.InstallErr != nil {
		return s.InstallErr
	}
	s.Installed = true
	return nil
}
func (s *stubServerApplier) IsRunning(_ context.Context) (bool, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.IsRunningCalls++
	return s.Running, nil
}
func (s *stubServerApplier) Start(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.StartCalls++
	if s.StartErr != nil {
		return s.StartErr
	}
	s.Running = true
	return nil
}
func (s *stubServerApplier) Stop(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.StopCalls++
	s.Running = false
	return nil
}
func (s *stubServerApplier) Version(_ context.Context) (string, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.VersionCalls++
	return s.Version_, nil
}
func (s *stubServerApplier) CaptureBootstrapState(_ context.Context) (BootstrapState, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.CaptureCalls++
	if s.BootstrapStateErr != nil {
		return BootstrapState{}, s.BootstrapStateErr
	}
	return s.BootstrapState, nil
}
func (s *stubServerApplier) Cleanup(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.CleanupCalls++
	s.Installed = false
	return nil
}

// stubModulesAPI returns a fixed list of assigned module names.
type stubModulesAPI struct {
	Modules []string
	Err     error
	Calls   int
}

func (s *stubModulesAPI) AssignedModules(_ context.Context) ([]string, error) {
	s.Calls++
	return s.Modules, s.Err
}

// fakeK3sPlatform stands up an httptest server that mirrors the
// platform runtime/handshake endpoint for K3s phases.
type fakeK3sPlatform struct {
	server *httptest.Server

	mu              sync.Mutex
	Bootstrap       int
	Ready           int
	Stopped         int
	JoinRequest     int
	LastBootstrap   HandshakeRequest
	LastReady       HandshakeRequest
	BootstrapClusterID string
}

func newFakeK3sPlatform(t *testing.T) *fakeK3sPlatform {
	t.Helper()
	fp := &fakeK3sPlatform{BootstrapClusterID: "cluster-test-123"}
	fp.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		_ = json.Unmarshal(body, &req)

		fp.mu.Lock()
		switch req.Phase {
		case PhaseBootstrap:
			fp.Bootstrap++
			fp.LastBootstrap = req
			fp.respond(w, map[string]any{
				"cluster_id":     fp.BootstrapClusterID,
				"cluster_status": "bootstrapping",
				"api_endpoint":   "https://[fd00::1]:6443",
			})
		case PhaseReady:
			fp.Ready++
			fp.LastReady = req
			fp.respond(w, map[string]any{
				"node_id":     "node-1",
				"cluster_id":  fp.BootstrapClusterID,
				"node_status": "active",
				"role":        req.Role,
			})
		case PhaseStopped:
			fp.Stopped++
			fp.respond(w, map[string]any{
				"acknowledged": true, "node_id": "node-1",
			})
		case PhaseJoinRequest:
			fp.JoinRequest++
			fp.respond(w, map[string]any{
				"cluster_id":   fp.BootstrapClusterID,
				"api_endpoint": "https://[fd00::1]:6443",
				"agent_token":  "K10agent-tok",
			})
		}
		fp.mu.Unlock()
	}))
	return fp
}

func (fp *fakeK3sPlatform) respond(w http.ResponseWriter, data map[string]any) {
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "data": data})
}
func (fp *fakeK3sPlatform) close()  { fp.server.Close() }
func (fp *fakeK3sPlatform) client() *Client {
	return NewClient(&transport.Client{Client: fp.server.Client(), PlatformURL: fp.server.URL})
}

// newTestServerManager wires the stubs together with a node ID.
func newTestServerManager(t *testing.T, modules []string, applier *stubServerApplier) (*ServerManager, *fakeK3sPlatform) {
	t.Helper()
	fp := newFakeK3sPlatform(t)
	mods := &stubModulesAPI{Modules: modules}
	errLog := func(stage string, err error) { t.Logf("[ServerManager] %s: %v", stage, err) }
	m := NewServerManager(fp.client(), mods, applier, "node-1", errLog)
	return m, fp
}

// ────────────────────────────────────────────────────────────────────
// State-machine tests — one per branch + multi-tick lifecycle.
// ────────────────────────────────────────────────────────────────────

func TestServerReconcile_AssignedNotInstalled_Installs(t *testing.T) {
	a := &stubServerApplier{}
	m, fp := newTestServerManager(t, []string{"k3s-server"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.InstallCalls != 1 {
		t.Fatalf("expected Install once, got %d", a.InstallCalls)
	}
	if !a.Installed {
		t.Fatal("expected Installed=true after Install")
	}
}

func TestServerReconcile_InstalledNotRunning_Starts(t *testing.T) {
	a := &stubServerApplier{Installed: true}
	m, fp := newTestServerManager(t, []string{"k3s-server"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.StartCalls != 1 {
		t.Fatalf("expected Start once, got %d", a.StartCalls)
	}
}

func TestServerReconcile_RunningNoBootstrap_PostsBootstrap(t *testing.T) {
	a := &stubServerApplier{
		Installed: true,
		Running:   true,
		Version_:  "v1.30.4+k3s1",
		BootstrapState: BootstrapState{
			Kubeconfig:  "fake-yaml",
			ServerToken: "K10srv",
			AgentToken:  "K10agt",
		},
	}
	m, fp := newTestServerManager(t, []string{"k3s-server"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if fp.Bootstrap != 1 {
		t.Fatalf("expected Bootstrap once, got %d", fp.Bootstrap)
	}
	if fp.LastBootstrap.Kubeconfig != "fake-yaml" {
		t.Fatalf("kubeconfig not propagated: %q", fp.LastBootstrap.Kubeconfig)
	}
	if fp.LastBootstrap.K8sVersion != "v1.30.4+k3s1" {
		t.Fatalf("version not propagated: %q", fp.LastBootstrap.K8sVersion)
	}
	if m.state.bootstrappedFor != fp.BootstrapClusterID {
		t.Fatalf("expected bootstrappedFor=%s, got %s", fp.BootstrapClusterID, m.state.bootstrappedFor)
	}
}

func TestServerReconcile_RunningEmptyBootstrap_Defers(t *testing.T) {
	// Daemon running but kubeconfig + token not yet ready — expected
	// during the first ~30s after k3s start. Should defer (no error,
	// no bootstrap call).
	a := &stubServerApplier{
		Installed: true, Running: true,
		BootstrapState: BootstrapState{}, // empty
	}
	m, fp := newTestServerManager(t, []string{"k3s-server"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if fp.Bootstrap != 0 {
		t.Fatalf("expected Bootstrap deferred, got %d calls", fp.Bootstrap)
	}
	if m.LastError() != nil {
		t.Fatalf("expected no error on deferred bootstrap, got %v", m.LastError())
	}
}

func TestServerReconcile_BootstrappedRunning_ReportsReady(t *testing.T) {
	a := &stubServerApplier{
		Installed: true, Running: true, Version_: "v1.30.4+k3s1",
		BootstrapState: BootstrapState{
			Kubeconfig: "kc", ServerToken: "tok", AgentToken: "atok",
		},
	}
	m, fp := newTestServerManager(t, []string{"k3s-server"}, a)
	defer fp.close()

	// T1: bootstrap
	m.Reconcile(context.Background())
	// T2: report ready (now that bootstrappedFor is set)
	m.Reconcile(context.Background())

	if fp.Ready != 1 {
		t.Fatalf("expected Ready once, got %d", fp.Ready)
	}
	if fp.LastReady.Role != RoleServer {
		t.Fatalf("expected role=server, got %q", fp.LastReady.Role)
	}
	if fp.LastReady.Version != "v1.30.4+k3s1" {
		t.Fatalf("expected version v1.30.4+k3s1, got %q", fp.LastReady.Version)
	}
}

func TestServerReconcile_NotAssignedRunning_Stops(t *testing.T) {
	a := &stubServerApplier{Installed: true, Running: true, Version_: "v1.30"}
	m, fp := newTestServerManager(t, []string{}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.StopCalls != 1 {
		t.Fatalf("expected Stop once, got %d", a.StopCalls)
	}
	if fp.Stopped != 1 {
		t.Fatalf("expected ReportStopped once, got %d", fp.Stopped)
	}
}

func TestServerReconcile_NotAssignedInstalled_Cleanup(t *testing.T) {
	a := &stubServerApplier{Installed: true, Running: false}
	m, fp := newTestServerManager(t, []string{}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.CleanupCalls != 1 {
		t.Fatalf("expected Cleanup once, got %d", a.CleanupCalls)
	}
	if a.Installed {
		t.Fatal("expected Installed=false after Cleanup")
	}
}

func TestServerReconcile_FullLifecycle(t *testing.T) {
	// Multi-tick: install → start → bootstrap → ready → idempotent
	a := &stubServerApplier{
		Version_: "v1.30.4+k3s1",
		BootstrapState: BootstrapState{
			Kubeconfig: "kc", ServerToken: "tok", AgentToken: "atok",
		},
	}
	m, fp := newTestServerManager(t, []string{"k3s-server"}, a)
	defer fp.close()

	// T1: not installed → install
	m.Reconcile(context.Background())
	if a.InstallCalls != 1 || !a.Installed {
		t.Fatalf("T1: expected install, got installs=%d installed=%v", a.InstallCalls, a.Installed)
	}

	// T2: installed but not running → start
	m.Reconcile(context.Background())
	if a.StartCalls != 1 || !a.Running {
		t.Fatalf("T2: expected start, got starts=%d running=%v", a.StartCalls, a.Running)
	}

	// T3: running, no bootstrap → bootstrap
	m.Reconcile(context.Background())
	if fp.Bootstrap != 1 {
		t.Fatalf("T3: expected bootstrap, got %d", fp.Bootstrap)
	}

	// T4: running, bootstrapped → ready
	m.Reconcile(context.Background())
	if fp.Ready != 1 {
		t.Fatalf("T4: expected ready, got %d", fp.Ready)
	}

	// T5+: steady state, ready idempotent
	m.Reconcile(context.Background())
	m.Reconcile(context.Background())
	if fp.Ready != 1 {
		t.Fatalf("T5+T6: ready should be idempotent, got %d", fp.Ready)
	}
}

func TestServerReconcile_ReportReady_Idempotent(t *testing.T) {
	// 5 ticks in steady state should fire exactly 1 ReportReady.
	a := &stubServerApplier{
		Installed: true, Running: true, Version_: "v1.30.4+k3s1",
		BootstrapState: BootstrapState{
			Kubeconfig: "kc", ServerToken: "tok", AgentToken: "atok",
		},
	}
	m, fp := newTestServerManager(t, []string{"k3s-server"}, a)
	defer fp.close()

	// First tick: bootstrap. Subsequent: ready (1 call total, then dedup).
	for i := 0; i < 6; i++ {
		m.Reconcile(context.Background())
	}
	if fp.Bootstrap != 1 {
		t.Fatalf("expected bootstrap once, got %d", fp.Bootstrap)
	}
	if fp.Ready != 1 {
		t.Fatalf("expected ready once across 6 ticks, got %d", fp.Ready)
	}
}

func TestServerReconcile_VersionChange_RefiresReady(t *testing.T) {
	a := &stubServerApplier{
		Installed: true, Running: true, Version_: "v1.30.4+k3s1",
		BootstrapState: BootstrapState{
			Kubeconfig: "kc", ServerToken: "tok", AgentToken: "atok",
		},
	}
	m, fp := newTestServerManager(t, []string{"k3s-server"}, a)
	defer fp.close()

	m.Reconcile(context.Background()) // bootstrap
	m.Reconcile(context.Background()) // ready v1.30.4
	a.Version_ = "v1.30.5+k3s1"
	m.Reconcile(context.Background()) // ready v1.30.5 (re-fires)

	if fp.Ready != 2 {
		t.Fatalf("expected version change to re-fire ready, got %d", fp.Ready)
	}
	if fp.LastReady.Version != "v1.30.5+k3s1" {
		t.Fatalf("expected last reported v1.30.5+k3s1, got %q", fp.LastReady.Version)
	}
}

func TestServerReconcile_StopIdempotent(t *testing.T) {
	a := &stubServerApplier{Installed: true, Running: true}
	m, fp := newTestServerManager(t, []string{}, a)
	defer fp.close()

	m.Reconcile(context.Background()) // T1: stop + report stopped
	m.Reconcile(context.Background()) // T2: still installed → cleanup
	m.Reconcile(context.Background()) // T3: nothing assigned, no install → no-op

	if fp.Stopped != 1 {
		t.Fatalf("ReportStopped should fire once, got %d", fp.Stopped)
	}
	if a.CleanupCalls != 1 {
		t.Fatalf("Cleanup should fire once, got %d", a.CleanupCalls)
	}
}

func TestServerReconcile_ModulesError_Recorded(t *testing.T) {
	a := &stubServerApplier{}
	fp := newFakeK3sPlatform(t)
	defer fp.close()
	mods := &stubModulesAPI{Err: errors.New("network down")}
	m := NewServerManager(fp.client(), mods, a, "node-1", func(string, error) {})

	m.Reconcile(context.Background())

	if m.LastError() == nil {
		t.Fatal("expected LastError after modules failure")
	}
	if a.HasInstalledCalls > 0 {
		t.Fatal("expected no further work past modules error")
	}
}

func TestServerReconcile_MissingNodeID_Errors(t *testing.T) {
	a := &stubServerApplier{}
	fp := newFakeK3sPlatform(t)
	defer fp.close()
	m := NewServerManager(fp.client(), &stubModulesAPI{Modules: []string{"k3s-server"}},
		a, "", func(string, error) {})

	m.Reconcile(context.Background())

	if m.LastError() == nil {
		t.Fatal("expected error for missing NodeID")
	}
	if a.HasInstalledCalls > 0 {
		t.Fatal("expected NodeID guard to short-circuit")
	}
}
