package k3sd

import (
	"context"
	"slices"
	"sync"
	"time"
)

// AgentModuleName is the catalog entry the agent watches for to know
// it should install + join an existing K3s cluster as a worker.
// Matches extensions/system/server/db/seeds/k3s_modules.rb.
const AgentModuleName = "k3s-agent"

// AgentManager owns the per-tick K3s agent (worker) reconcile loop.
// One per agent process. Mirrors ServerManager's shape but with a
// join_request flow instead of bootstrap:
//
//   1. Module not assigned + daemon running → Stop + ReportStopped
//   2. Module not assigned + binary installed → Cleanup
//   3. Module assigned + binary missing → Install
//   4. Module assigned + binary present + no join config → JoinRequest
//      + WriteJoinConfig
//   5. Module assigned + join config present + daemon stopped → Start
//   6. Module assigned + daemon running + not yet ack'd ready
//      → ReportReady
//   7. Otherwise → no-op
//
// Difference from ServerManager: order matters. Worker needs to
// fetch its membership material BEFORE starting k3s-agent, because
// the systemd unit reads K3S_URL + K3S_TOKEN from env at start. So
// the join_request → write config → start sequence runs across
// multiple ticks.
type AgentManager struct {
	Client  *Client
	Modules ModulesAPI
	Applier AgentApplier
	NodeID  string
	OnError func(stage string, err error)

	mu              sync.Mutex
	lastReconcileAt time.Time
	lastError       error
	state           agentState
}

type agentState struct {
	// joinedClusterID is set to the cluster_id once we've successfully
	// fetched the join material + persisted it. Cleared on Cleanup.
	joinedClusterID string

	// readyReportedFor is set to the running version once we've
	// successfully called ReportReady. Cleared when daemon stops or
	// version changes (rolling-upgrade re-fires).
	readyReportedFor string

	// stoppedReportedAt is set when ReportStopped has been called;
	// cleared when the daemon comes back up.
	stoppedReportedAt time.Time
}

func NewAgentManager(client *Client, modules ModulesAPI, applier AgentApplier,
	nodeID string, onError func(string, error)) *AgentManager {
	if onError == nil {
		onError = func(string, error) {}
	}
	return &AgentManager{
		Client:  client,
		Modules: modules,
		Applier: applier,
		NodeID:  nodeID,
		OnError: onError,
	}
}

func (m *AgentManager) Reconcile(ctx context.Context) {
	m.mu.Lock()
	defer m.mu.Unlock()
	defer func() { m.lastReconcileAt = time.Now() }()

	if m.NodeID == "" {
		m.recordError("config", errMissingNodeID)
		return
	}

	assigned, err := m.Modules.AssignedModules(ctx)
	if err != nil {
		m.recordError("list_modules", err)
		return
	}
	desired := slices.Contains(assigned, AgentModuleName)

	installed, err := m.Applier.HasInstalled(ctx)
	if err != nil {
		m.recordError("has_installed", err)
		return
	}
	running, err := m.Applier.IsRunning(ctx)
	if err != nil {
		m.recordError("is_running", err)
		return
	}
	hasJoin, err := m.Applier.HasJoinConfig(ctx)
	if err != nil {
		m.recordError("has_join_config", err)
		return
	}

	switch {
	case !desired && running:
		m.transitionStop(ctx)
	case !desired && installed:
		m.transitionCleanup(ctx)
	case desired && !installed:
		m.transitionInstall(ctx)
	case desired && installed && !hasJoin:
		m.transitionJoinRequest(ctx)
	case desired && installed && hasJoin && !running:
		m.transitionStart(ctx)
	case desired && running:
		m.transitionReportReady(ctx)
	}
}

// ──────────────────────────────────────────────────────────────────
// Transition handlers
// ──────────────────────────────────────────────────────────────────

func (m *AgentManager) transitionInstall(ctx context.Context) {
	if err := m.Applier.InstallK3sAgent(ctx); err != nil {
		m.recordError("install", err)
		return
	}
	m.state.joinedClusterID = ""
	m.state.readyReportedFor = ""
}

func (m *AgentManager) transitionJoinRequest(ctx context.Context) {
	payload, err := m.Client.JoinRequest(ctx)
	if err != nil {
		// NoClusterAvailable is the common case during the first
		// minute of a fresh deployment — server hasn't bootstrapped
		// yet. Recorded as an error so operators see what's
		// blocking, but doesn't crash the loop. Resolves itself once
		// the server's bootstrap phase completes.
		m.recordError("join_request", err)
		return
	}
	cfg := AgentJoinConfig{
		APIEndpoint: payload.APIEndpoint,
		AgentToken:  payload.AgentToken,
		CAPem:       payload.CAPem,
	}
	if err := m.Applier.WriteJoinConfig(ctx, cfg); err != nil {
		m.recordError("write_join_config", err)
		return
	}
	m.state.joinedClusterID = payload.ClusterID
	m.state.readyReportedFor = ""
}

func (m *AgentManager) transitionStart(ctx context.Context) {
	if err := m.Applier.Start(ctx); err != nil {
		m.recordError("start", err)
		return
	}
	m.state.stoppedReportedAt = time.Time{}
}

func (m *AgentManager) transitionReportReady(ctx context.Context) {
	version, err := m.Applier.Version(ctx)
	if err != nil {
		m.recordError("version", err)
	}
	if m.state.readyReportedFor == version && version != "" {
		return
	}
	if _, err := m.Client.ReportReady(ctx, RuntimeK3sAgent, RoleAgent, version); err != nil {
		m.recordError("report_ready", err)
		return
	}
	m.state.readyReportedFor = version
}

func (m *AgentManager) transitionStop(ctx context.Context) {
	if err := m.Applier.Stop(ctx); err != nil {
		m.recordError("stop", err)
	}
	if !m.state.stoppedReportedAt.IsZero() {
		return
	}
	if _, err := m.Client.ReportStopped(ctx, RuntimeK3sAgent); err != nil {
		m.recordError("report_stopped", err)
		return
	}
	m.state.stoppedReportedAt = time.Now()
	m.state.readyReportedFor = ""
	m.state.joinedClusterID = ""
}

func (m *AgentManager) transitionCleanup(ctx context.Context) {
	if err := m.Applier.Cleanup(ctx); err != nil {
		m.recordError("cleanup", err)
		return
	}
	m.state.joinedClusterID = ""
	m.state.readyReportedFor = ""
	m.state.stoppedReportedAt = time.Time{}
}

func (m *AgentManager) recordError(stage string, err error) {
	m.lastError = err
	m.OnError(stage, err)
}

func (m *AgentManager) LastReconcileAt() time.Time {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastReconcileAt
}

func (m *AgentManager) LastError() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastError
}
