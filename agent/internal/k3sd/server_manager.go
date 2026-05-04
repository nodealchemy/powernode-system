package k3sd

import (
	"context"
	"slices"
	"sync"
	"time"
)

// ServerModuleName is the catalog entry the agent watches for to know
// it should install + bootstrap a K3s server. Matches the seed file
// in extensions/system/server/db/seeds/k3s_modules.rb.
const ServerModuleName = "k3s-server"

// ServerManager owns the per-tick K3s server reconcile loop. One per
// agent process. Designed to be invoked from the heartbeat
// goroutine's PostSend hook — same shape as dockerd.Manager.
//
// The state machine (top-down, first matching branch fires per tick;
// multi-step transitions take multiple ticks):
//
//   1. Module not assigned + daemon running → Stop + ReportStopped
//   2. Module not assigned + binary installed → Cleanup
//   3. Module assigned + binary missing → Install
//   4. Module assigned + binary present + daemon stopped → Start
//   5. Module assigned + daemon running + cluster NOT yet bootstrapped
//      → CaptureBootstrapState + Bootstrap call
//   6. Module assigned + daemon running + cluster bootstrapped + not
//      yet ack'd ready → ReportReady
//   7. Otherwise (steady state) → no-op
type ServerManager struct {
	Client  *Client
	Modules ModulesAPI
	Applier ServerApplier
	NodeID  string
	OnError func(stage string, err error)

	mu              sync.Mutex
	lastReconcileAt time.Time
	lastError       error
	state           serverState
}

// serverState caches what's been reported / persisted across ticks so
// we don't spam the platform with redundant calls.
type serverState struct {
	// bootstrappedFor is set to the cluster_id once we've successfully
	// posted phase=bootstrap. Cleared on Cleanup. Stops the
	// reconciler from re-bootstrapping every 30 seconds.
	bootstrappedFor string

	// readyReportedFor is set to the running daemon version once
	// we've successfully called ReportReady. Cleared when the
	// daemon stops or version changes.
	readyReportedFor string

	// stoppedReportedAt is set when we've successfully called
	// ReportStopped; cleared when the daemon comes back up.
	stoppedReportedAt time.Time
}

// NewServerManager constructs a ServerManager with sensible defaults.
func NewServerManager(client *Client, modules ModulesAPI, applier ServerApplier,
	nodeID string, onError func(string, error)) *ServerManager {
	if onError == nil {
		onError = func(string, error) {}
	}
	return &ServerManager{
		Client:  client,
		Modules: modules,
		Applier: applier,
		NodeID:  nodeID,
		OnError: onError,
	}
}

// Reconcile runs a single tick. Errors surface via OnError but the
// function itself never returns one — matches dockerd.Manager so a
// transient K3s failure can't kill the heartbeat goroutine.
func (m *ServerManager) Reconcile(ctx context.Context) {
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
	desired := slices.Contains(assigned, ServerModuleName)

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

	switch {
	case !desired && running:
		m.transitionStop(ctx)
	case !desired && installed:
		m.transitionCleanup(ctx)
	case desired && !installed:
		m.transitionInstall(ctx)
	case desired && installed && !running:
		m.transitionStart(ctx)
	case desired && running && m.state.bootstrappedFor == "":
		m.transitionBootstrap(ctx)
	case desired && running && m.state.bootstrappedFor != "":
		m.transitionReportReady(ctx)
	}
}

// ──────────────────────────────────────────────────────────────────
// Transition handlers
// ──────────────────────────────────────────────────────────────────

func (m *ServerManager) transitionInstall(ctx context.Context) {
	if err := m.Applier.InstallK3sServer(ctx); err != nil {
		m.recordError("install", err)
		return
	}
	// Reset state so the next tick (which finds installed + not
	// running) triggers Start, then Bootstrap, then ReportReady.
	m.state.bootstrappedFor = ""
	m.state.readyReportedFor = ""
}

func (m *ServerManager) transitionStart(ctx context.Context) {
	if err := m.Applier.Start(ctx); err != nil {
		m.recordError("start", err)
		return
	}
	m.state.stoppedReportedAt = time.Time{}
}

func (m *ServerManager) transitionBootstrap(ctx context.Context) {
	bootstrap, err := m.Applier.CaptureBootstrapState(ctx)
	if err != nil {
		m.recordError("capture_bootstrap", err)
		return
	}
	if bootstrap.Kubeconfig == "" || bootstrap.ServerToken == "" {
		// Daemon hasn't finished bootstrap yet — common during the
		// first ~30s after `systemctl start k3s`. Defer to the next
		// tick. This is an EXPECTED state, not an error.
		return
	}

	version, _ := m.Applier.Version(ctx)
	ack, err := m.Client.Bootstrap(ctx, bootstrap.Kubeconfig,
		bootstrap.ServerToken, bootstrap.AgentToken, version)
	if err != nil {
		m.recordError("bootstrap", err)
		return
	}
	m.state.bootstrappedFor = ack.ClusterID
	// Clear ready cache so the next tick re-fires ReportReady for
	// the now-known cluster.
	m.state.readyReportedFor = ""
}

func (m *ServerManager) transitionReportReady(ctx context.Context) {
	version, err := m.Applier.Version(ctx)
	if err != nil {
		m.recordError("version", err)
		// Continue — empty version still meaningful for "I'm alive".
	}
	if m.state.readyReportedFor == version && version != "" {
		return // idempotent — already reported this version
	}
	if _, err := m.Client.ReportReady(ctx, RuntimeK3sServer, RoleServer, version); err != nil {
		m.recordError("report_ready", err)
		return
	}
	m.state.readyReportedFor = version
}

func (m *ServerManager) transitionStop(ctx context.Context) {
	if err := m.Applier.Stop(ctx); err != nil {
		m.recordError("stop", err)
		// Continue — best-effort, ReportStopped still useful.
	}
	if !m.state.stoppedReportedAt.IsZero() {
		return // already reported
	}
	if _, err := m.Client.ReportStopped(ctx, RuntimeK3sServer); err != nil {
		m.recordError("report_stopped", err)
		return
	}
	m.state.stoppedReportedAt = time.Now()
	m.state.readyReportedFor = ""
	m.state.bootstrappedFor = ""
}

func (m *ServerManager) transitionCleanup(ctx context.Context) {
	if err := m.Applier.Cleanup(ctx); err != nil {
		m.recordError("cleanup", err)
		return
	}
	m.state.bootstrappedFor = ""
	m.state.readyReportedFor = ""
	m.state.stoppedReportedAt = time.Time{}
}

func (m *ServerManager) recordError(stage string, err error) {
	m.lastError = err
	m.OnError(stage, err)
}

// LastReconcileAt is exposed for the heartbeat status reporter.
func (m *ServerManager) LastReconcileAt() time.Time {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastReconcileAt
}

// LastError returns the most recent error recorded by Reconcile (or
// nil). Same purpose as LastReconcileAt — heartbeat observability.
func (m *ServerManager) LastError() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastError
}

var errMissingNodeID = sentinelError("k3sd ServerManager: NodeID required")

type sentinelError string

func (e sentinelError) Error() string { return string(e) }
