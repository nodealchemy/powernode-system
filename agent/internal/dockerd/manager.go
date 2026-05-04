package dockerd

import (
	"context"
	"slices"
	"sync"
	"time"
)

// ModuleName is the catalog entry the agent watches for to know it
// should provision a Docker daemon. Matches the seed file in
// extensions/system/server/db/seeds/docker_runtime_module.rb.
const ModuleName = "docker-engine"

// Manager owns the per-tick docker daemon reconcile loop. One per
// agent process. Designed to be invoked from the heartbeat
// goroutine's PostSend hook — same shape as Sdwan::Manager.
//
// Reconcile is safe to call concurrently: the manager serializes
// internal state via a mutex. In practice it's only invoked from
// one goroutine, but the lock keeps state inspection (for tests)
// race-free.
type Manager struct {
	Client       *Client       // dockerd protocol client
	Modules      ModulesAPI    // assigned-modules query
	Applier      DaemonApplier // file IO + systemctl
	NodeID       string        // System::NodeInstance UUID, used as CN suffix
	OverlayAddress string      // SDWAN /128 the daemon should bind, no brackets
	Paths        DaemonPaths   // on-disk layout — defaults to DefaultPaths
	OnError      func(stage string, err error)

	mu              sync.Mutex
	lastReconcileAt time.Time
	lastError       error
	state           managedState
}

// managedState caches what's been reported / persisted across ticks so
// we don't re-POST ready every 30 seconds.
type managedState struct {
	// readyReportedFor is set to the running daemon version once we've
	// successfully called ReportReady. Cleared when the daemon stops.
	// Stops the reconciler from spamming the platform.
	readyReportedFor string
	// stoppedReportedAt is set when we've successfully called
	// ReportStopped; cleared when the daemon comes back up.
	stoppedReportedAt time.Time
}

// NewManager constructs a Manager with sensible defaults. Paths
// defaults to DefaultPaths if zero-valued.
func NewManager(client *Client, modules ModulesAPI, applier DaemonApplier,
	nodeID, overlayAddress string, onError func(string, error)) *Manager {
	if onError == nil {
		onError = func(string, error) {}
	}
	m := &Manager{
		Client:         client,
		Modules:        modules,
		Applier:        applier,
		NodeID:         nodeID,
		OverlayAddress: overlayAddress,
		Paths:          DefaultPaths,
		OnError:        onError,
	}
	return m
}

// Reconcile runs a single tick of the reconcile loop. Errors are
// surfaced via OnError but the function itself never returns one —
// matches Sdwan::Manager so a transient docker failure can't kill the
// heartbeat goroutine.
//
// State machine (decision branches checked top-down, first matching
// branch fires per tick — multi-step transitions take multiple ticks):
//
//   1. Module not assigned + daemon running → Stop daemon, report stopped
//   2. Module not assigned + cert on disk    → Remove cert (final cleanup)
//   3. Module assigned + cert missing        → wants_cert handshake → write
//   4. Module assigned + cert present + daemon stopped → write config + start
//   5. Module assigned + daemon running + not yet ack'd → ReportReady
//   6. Otherwise (steady state)              → no-op
func (m *Manager) Reconcile(ctx context.Context) {
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
	desired := slices.Contains(assigned, ModuleName)

	hasCert, err := m.Applier.HasCert(ctx)
	if err != nil {
		m.recordError("has_cert", err)
		return
	}
	running, err := m.Applier.IsDaemonRunning(ctx)
	if err != nil {
		m.recordError("is_running", err)
		return
	}

	switch {
	case !desired && running:
		m.transitionStop(ctx)
	case !desired && hasCert:
		m.transitionCleanupCert(ctx)
	case desired && !hasCert:
		m.transitionRequestCert(ctx)
	case desired && hasCert && !running:
		m.transitionStart(ctx)
	case desired && running:
		m.transitionReportReady(ctx)
	}
	// fallthrough → steady state, nothing to do
}

func (m *Manager) transitionRequestCert(ctx context.Context) {
	kp, signed, err := m.Client.RequestServerCert(ctx, m.NodeID)
	if err != nil {
		m.recordError("request_cert", err)
		return
	}
	keyPEM, err := kp.PrivatePEM()
	if err != nil {
		m.recordError("marshal_key", err)
		return
	}
	material := CertMaterial{
		CAChainPEM:    signed.CAChainPEM,
		ServerCertPEM: signed.CertPEM,
		ServerKeyPEM:  string(keyPEM),
	}
	if err := m.Applier.WriteCert(ctx, material); err != nil {
		m.recordError("write_cert", err)
		return
	}
	// Reset ready-reported state so the next tick (which finds
	// daemon-not-yet-running) eventually triggers ReportReady.
	m.state.readyReportedFor = ""
}

func (m *Manager) transitionStart(ctx context.Context) {
	cfg := DaemonConfig{
		ListenAddress: "tcp://[" + m.OverlayAddress + "]:2376",
		TLSCAPath:     m.Paths.CAFile,
		TLSCertPath:   m.Paths.CertFile,
		TLSKeyPath:    m.Paths.KeyFile,
	}
	if err := m.Applier.WriteDaemonConfig(ctx, cfg); err != nil {
		m.recordError("write_daemon_config", err)
		return
	}
	if err := m.Applier.StartDaemon(ctx); err != nil {
		m.recordError("start_daemon", err)
		return
	}
	// Daemon is now (presumably) starting; the next tick will see it
	// running and fire transitionReportReady. We don't ReportReady
	// here because the daemon may still be initializing — wait until
	// the next tick confirms `IsDaemonRunning == true`.
	m.state.stoppedReportedAt = time.Time{} // clear stale stopped marker
}

func (m *Manager) transitionReportReady(ctx context.Context) {
	version, err := m.Applier.DaemonVersion(ctx)
	if err != nil {
		m.recordError("daemon_version", err)
		// Don't return — we can still report ready with empty version.
		// The platform records nil version metadata; operators see "?"
		// instead of the wrong version.
	}
	if m.state.readyReportedFor == version && version != "" {
		// Idempotent: same version already reported in a prior tick,
		// don't re-POST. Cleared on cert refresh, daemon stop, or
		// version change.
		return
	}
	listen := "tcp://[" + m.OverlayAddress + "]:2376"
	if _, err := m.Client.ReportReady(ctx, version, listen); err != nil {
		m.recordError("report_ready", err)
		return
	}
	m.state.readyReportedFor = version
}

func (m *Manager) transitionStop(ctx context.Context) {
	if err := m.Applier.StopDaemon(ctx); err != nil {
		m.recordError("stop_daemon", err)
		// Continue — best-effort cleanup. ReportStopped still useful
		// to flip the platform-side host status from connected to
		// disconnected promptly.
	}
	if !m.state.stoppedReportedAt.IsZero() {
		return // already reported, stay idempotent
	}
	if _, err := m.Client.ReportStopped(ctx); err != nil {
		m.recordError("report_stopped", err)
		return
	}
	m.state.stoppedReportedAt = time.Now()
	m.state.readyReportedFor = ""
}

func (m *Manager) transitionCleanupCert(ctx context.Context) {
	if err := m.Applier.RemoveCert(ctx); err != nil {
		m.recordError("remove_cert", err)
		return
	}
	m.state.readyReportedFor = ""
	m.state.stoppedReportedAt = time.Time{}
}

func (m *Manager) recordError(stage string, err error) {
	m.lastError = err
	m.OnError(stage, err)
}

// LastReconcileAt is exposed for the heartbeat status reporter — lets
// the agent surface "last docker reconcile: 12s ago" in its
// observability snapshot.
func (m *Manager) LastReconcileAt() time.Time {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastReconcileAt
}

// LastError is the last error recorded by Reconcile (or nil). Same
// purpose as LastReconcileAt.
func (m *Manager) LastError() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastError
}

// errMissingNodeID is the sentinel for misconfiguration — the agent
// should never construct a Manager without a NodeID, but defense in
// depth catches the bug at reconcile time instead of at first
// platform call.
var errMissingNodeID = sentinelError("dockerd Manager: NodeID required")

type sentinelError string

func (e sentinelError) Error() string { return string(e) }
