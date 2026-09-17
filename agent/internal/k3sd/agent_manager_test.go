package k3sd

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
)

// stubAgentApplier is the in-memory AgentApplier used by all
// agent state-machine tests.
type stubAgentApplier struct {
	mu sync.Mutex

	Installed    bool
	Running      bool
	HasJoin      bool
	Version_     string
	JoinConfig   AgentJoinConfig
	WriteJoinErr error

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
	s.mu.Lock()
	defer s.mu.Unlock()
	s.HasInstalledCalls++
	return s.Installed, nil
}
func (s *stubAgentApplier) InstallK3sAgent(_ context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.InstallCalls++
	s.Installed = true
	return nil
}
func (s *stubAgentApplier) IsRunning(_ context.Context) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.IsRunningCalls++
	return s.Running, nil
}
func (s *stubAgentApplier) Start(_ context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.StartCalls++
	s.Running = true
	return nil
}
func (s *stubAgentApplier) Stop(_ context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.StopCalls++
	s.Running = false
	return nil
}
func (s *stubAgentApplier) Version(_ context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.VersionCalls++
	return s.Version_, nil
}
func (s *stubAgentApplier) HasJoinConfig(_ context.Context) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.HasJoinCalls++
	return s.HasJoin, nil
}
func (s *stubAgentApplier) WriteJoinConfig(_ context.Context, cfg AgentJoinConfig) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.WriteJoinCalls++
	if s.WriteJoinErr != nil {
		return s.WriteJoinErr
	}
	s.JoinConfig = cfg
	s.HasJoin = true
	return nil
}
func (s *stubAgentApplier) Cleanup(_ context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
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
	// Test isolation: see dockerd manager_test.go's identical fix.
	m.StatePath = filepath.Join(t.TempDir(), "k3sd_agent_state.json")
	m.state = agentState{}
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

// IMP-a5f236e8cc56 gap 3 — TargetClusterID now has a producer
// (runtime/service.go refreshes it from HTTPAgentConfigClient before
// each Reconcile, mirroring ServerManager.Bootstrap). These three
// pin AgentManager's existing consumption of the field: whatever the
// refresh sets, join_request carries verbatim.
func TestAgentReconcile_JoinRequest_PassesStubTargetClusterID(t *testing.T) {
	a := &stubAgentApplier{Installed: true}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	// Simulate the tick-hook refresh runtime/service.go performs
	// before calling Reconcile.
	m.TargetClusterID = "cluster-stub-xyz"

	m.Reconcile(context.Background())

	if fp.JoinRequest != 1 {
		t.Fatalf("expected JoinRequest once, got %d", fp.JoinRequest)
	}
	if fp.LastJoinRequest.TargetClusterID != "cluster-stub-xyz" {
		t.Fatalf("TargetClusterID not forwarded to join_request: got %q, want %q",
			fp.LastJoinRequest.TargetClusterID, "cluster-stub-xyz")
	}
}

func TestAgentReconcile_JoinRequest_EmptyTargetClusterIDStaysEmpty(t *testing.T) {
	a := &stubAgentApplier{Installed: true}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	// No refresh happened yet (e.g. first tick, or every prior fetch
	// 403'd) — TargetClusterID stays at its zero value.
	if m.TargetClusterID != "" {
		t.Fatalf("expected zero-value TargetClusterID, got %q", m.TargetClusterID)
	}

	m.Reconcile(context.Background())

	if fp.JoinRequest != 1 {
		t.Fatalf("expected JoinRequest once, got %d", fp.JoinRequest)
	}
	if fp.LastJoinRequest.TargetClusterID != "" {
		t.Fatalf("expected empty target_cluster_id on the wire, got %q", fp.LastJoinRequest.TargetClusterID)
	}
	// And the join still proceeds — single-cluster auto-select path
	// keeps working exactly as it did before this field had a
	// producer.
	if m.state.joinedClusterID != fp.BootstrapClusterID {
		t.Fatalf("join did not proceed with empty target: joinedClusterID = %q", m.state.joinedClusterID)
	}
}

// A refresh fetch error (network blip, 500, etc.) must not block the
// join: runtime/service.go records it via OnError and leaves
// TargetClusterID at its last-known value (mirrors the Bootstrap
// fetch-error handling for ServerManager) rather than blanking it or
// aborting the tick. Modelled here at the AgentManager level, since
// that's the boundary the field crosses: whatever value survives a
// failed refresh is what join_request carries, and the join still
// completes.
func TestAgentReconcile_JoinRequest_StaleTargetClusterIDSurvivesAFailedRefresh(t *testing.T) {
	a := &stubAgentApplier{Installed: true}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	// A prior successful refresh set this; the current tick's fetch
	// failed (simulated by simply not overwriting it, exactly what
	// runtime/service.go's `if err != nil { OnError(...) } else {
	// assign }` shape does).
	m.TargetClusterID = "cluster-last-known-good"

	m.Reconcile(context.Background())

	if fp.LastJoinRequest.TargetClusterID != "cluster-last-known-good" {
		t.Fatalf("stale value not preserved through a failed refresh: got %q",
			fp.LastJoinRequest.TargetClusterID)
	}
	if m.state.joinedClusterID != fp.BootstrapClusterID {
		t.Fatalf("join did not proceed after a failed refresh: joinedClusterID = %q", m.state.joinedClusterID)
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

// IMP-a5f236e8cc56 gap 3 — with TargetClusterID now refreshed live from the
// platform every tick, an already-joined worker must NOT re-resolve its
// membership from that live value on phase=ready: it reports its own
// CACHED joinedClusterID (state.joinedClusterID, set once at join time),
// never the current TargetClusterID. Otherwise an operator changing
// target_cluster_id on the assignment after a join would silently
// "move" the worker's ready re-fires onto a different cluster it never
// actually joined.
func TestAgentReconcile_ReportReady_UsesCachedJoinNotLiveTarget(t *testing.T) {
	a := &stubAgentApplier{Installed: true, HasJoin: true, Running: true,
		Version_: "v1.30.4+k3s1"}
	m, fp := newTestAgentManager(t, []string{"k3s-agent"}, a)
	defer fp.close()

	// Simulate: this worker already joined cluster A (cached in state),
	// and the operator has since repointed the assignment's
	// target_cluster_id at a DIFFERENT cluster B — the live value a
	// runtime/service.go refresh would now be feeding in.
	m.state.joinedClusterID = "cluster-A-already-joined"
	m.TargetClusterID = "cluster-B-newly-configured"

	m.Reconcile(context.Background())

	if fp.Ready != 1 {
		t.Fatalf("expected Ready once, got %d", fp.Ready)
	}
	if fp.LastReady.ClusterID != "cluster-A-already-joined" {
		t.Fatalf("ReportReady used %q, want the cached join cluster %q (must not relocate on live TargetClusterID)",
			fp.LastReady.ClusterID, "cluster-A-already-joined")
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
