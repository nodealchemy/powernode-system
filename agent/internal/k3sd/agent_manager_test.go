package k3sd

import (
	"context"
	"sync"
	"testing"
)

// stubAgentApplier is the in-memory AgentApplier used by all
// agent state-machine tests.
type stubAgentApplier struct {
	mu sync.Mutex

	Installed       bool
	Running         bool
	HasJoin         bool
	Version_        string
	JoinConfig      AgentJoinConfig
	WriteJoinErr    error

	HasInstalledCalls int
	InstallCalls      int
	IsRunningCalls    int
	StartCalls        int
	StopCalls         int
	VersionCalls      int
	HasJoinCalls      int
	WriteJoinCalls    int
	CleanupCalls      int
}

func (s *stubAgentApplier) HasInstalled(_ context.Context) (bool, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.HasInstalledCalls++
	return s.Installed, nil
}
func (s *stubAgentApplier) InstallK3sAgent(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.InstallCalls++
	s.Installed = true
	return nil
}
func (s *stubAgentApplier) IsRunning(_ context.Context) (bool, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.IsRunningCalls++
	return s.Running, nil
}
func (s *stubAgentApplier) Start(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.StartCalls++
	s.Running = true
	return nil
}
func (s *stubAgentApplier) Stop(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.StopCalls++
	s.Running = false
	return nil
}
func (s *stubAgentApplier) Version(_ context.Context) (string, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.VersionCalls++
	return s.Version_, nil
}
func (s *stubAgentApplier) HasJoinConfig(_ context.Context) (bool, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.HasJoinCalls++
	return s.HasJoin, nil
}
func (s *stubAgentApplier) WriteJoinConfig(_ context.Context, cfg AgentJoinConfig) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.WriteJoinCalls++
	if s.WriteJoinErr != nil {
		return s.WriteJoinErr
	}
	s.JoinConfig = cfg
	s.HasJoin = true
	return nil
}
func (s *stubAgentApplier) Cleanup(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.CleanupCalls++
	s.Installed = false
	s.HasJoin = false
	return nil
}

func newTestAgentManager(t *testing.T, modules []string, applier *stubAgentApplier) (*AgentManager, *fakeK3sPlatform) {
	t.Helper()
	fp := newFakeK3sPlatform(t)
	mods := &stubModulesAPI{Modules: modules}
	errLog := func(stage string, err error) { t.Logf("[AgentManager] %s: %v", stage, err) }
	m := NewAgentManager(fp.client(), mods, applier, "node-w1", errLog)
	return m, fp
}

// ────────────────────────────────────────────────────────────────────
// Agent state-machine tests
// ────────────────────────────────────────────────────────────────────

func TestAgentReconcile_AssignedNotInstalled_Installs(t *testing.T) {
	a := &stubAgentApplier{}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.InstallCalls != 1 {
		t.Fatalf("expected Install once, got %d", a.InstallCalls)
	}
}

func TestAgentReconcile_InstalledNoJoin_FetchesAndWrites(t *testing.T) {
	a := &stubAgentApplier{Installed: true}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if fp.JoinRequest != 1 {
		t.Fatalf("expected JoinRequest once, got %d", fp.JoinRequest)
	}
	if a.WriteJoinCalls != 1 {
		t.Fatalf("expected WriteJoinConfig once, got %d", a.WriteJoinCalls)
	}
	if a.JoinConfig.AgentToken != "K10agent-tok" {
		t.Fatalf("agent_token not propagated: %q", a.JoinConfig.AgentToken)
	}
	if a.JoinConfig.APIEndpoint != "https://[fd00::1]:6443" {
		t.Fatalf("api_endpoint not propagated: %q", a.JoinConfig.APIEndpoint)
	}
	if m.state.joinedClusterID != fp.BootstrapClusterID {
		t.Fatalf("joinedClusterID not set: %q", m.state.joinedClusterID)
	}
}

func TestAgentReconcile_HasJoinNotRunning_Starts(t *testing.T) {
	a := &stubAgentApplier{Installed: true, HasJoin: true}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.StartCalls != 1 {
		t.Fatalf("expected Start once, got %d", a.StartCalls)
	}
}

func TestAgentReconcile_RunningNoReady_ReportsReady(t *testing.T) {
	a := &stubAgentApplier{Installed: true, HasJoin: true, Running: true,
		Version_: "v1.30.4+k3s1"}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if fp.Ready != 1 {
		t.Fatalf("expected Ready once, got %d", fp.Ready)
	}
	if fp.LastReady.Role != RoleAgent {
		t.Fatalf("expected role=agent, got %q", fp.LastReady.Role)
	}
}

func TestAgentReconcile_NotAssignedRunning_Stops(t *testing.T) {
	a := &stubAgentApplier{Installed: true, HasJoin: true, Running: true}
	m, fp := newTestAgentManager(t, []string{}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.StopCalls != 1 || fp.Stopped != 1 {
		t.Fatalf("expected Stop+ReportStopped, got stops=%d reports=%d", a.StopCalls, fp.Stopped)
	}
}

func TestAgentReconcile_NotAssignedInstalled_Cleanup(t *testing.T) {
	a := &stubAgentApplier{Installed: true, HasJoin: true, Running: false}
	m, fp := newTestAgentManager(t, []string{}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.CleanupCalls != 1 {
		t.Fatalf("expected Cleanup once, got %d", a.CleanupCalls)
	}
}

func TestAgentReconcile_FullLifecycle(t *testing.T) {
	// Multi-tick: install → join_request → start → ready
	a := &stubAgentApplier{Version_: "v1.30.4+k3s1"}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	m.Reconcile(context.Background()) // T1: install
	if a.InstallCalls != 1 {
		t.Fatalf("T1: expected install")
	}
	m.Reconcile(context.Background()) // T2: join_request
	if fp.JoinRequest != 1 || !a.HasJoin {
		t.Fatalf("T2: expected join_request, got jr=%d hasJoin=%v", fp.JoinRequest, a.HasJoin)
	}
	m.Reconcile(context.Background()) // T3: start
	if a.StartCalls != 1 || !a.Running {
		t.Fatalf("T3: expected start")
	}
	m.Reconcile(context.Background()) // T4: ready
	if fp.Ready != 1 {
		t.Fatalf("T4: expected ready, got %d", fp.Ready)
	}
	m.Reconcile(context.Background()) // T5: idempotent
	if fp.Ready != 1 {
		t.Fatalf("T5: ready should be idempotent")
	}
}

func TestAgentReconcile_VersionChange_RefiresReady(t *testing.T) {
	a := &stubAgentApplier{Installed: true, HasJoin: true, Running: true,
		Version_: "v1.30.4+k3s1"}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	m.Reconcile(context.Background())
	a.Version_ = "v1.30.5+k3s1"
	m.Reconcile(context.Background())

	if fp.Ready != 2 {
		t.Fatalf("expected version change to re-fire ready, got %d", fp.Ready)
	}
}
