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
	Overrides    OverridesAPI  // operator daemon.json overrides (slice 10; nil = no operator overrides)
	Applier      DaemonApplier // file IO + systemctl
	NodeID       string        // System::NodeInstance UUID, used as CN suffix
	OverlayAddress string      // SDWAN /128 the daemon should bind, no brackets
	Paths        DaemonPaths   // on-disk layout — defaults to DefaultPaths
	StatePath    string        // JSON state cache path; defaults to DefaultStatePath
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
	// lastConfigHash is the platform-supplied content_hash of the
	// daemon overrides we last applied to /etc/docker/daemon.json
	// (slice 10). Used by Reconcile to detect when operator overrides
	// have changed since the last apply, triggering a daemon restart.
	// Empty string means "no prior apply known" — first tick after
	// agent start should NOT trigger a restart even if overrides exist
	// on the platform side; the daemon already runs with whatever is
	// on disk, and the next genuine config change will trigger the
	// restart correctly.
	lastConfigHash string
}

// NewManager constructs a Manager with sensible defaults. Paths
// defaults to DefaultPaths; StatePath defaults to DefaultStatePath.
// Loads persisted state from disk so the reconciler doesn't lose its
// ready-reported / stopped-reported memory across agent restarts.
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
		StatePath:      DefaultStatePath,
		OnError:        onError,
	}
	m.loadState()
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

	// Guard branches that bind to a listen address. If sdwan hasn't
	// populated OverlayAddress yet, defer those transitions to the
	// next tick. Cert request + cleanup paths are address-independent
	// and can still proceed.
	hasOverlay := m.OverlayAddress != ""

	// Slice 10 — when steady-state running, fetch operator overrides
	// to detect changes that warrant a daemon restart. We only fetch
	// in the running branch (not on the start path; transitionStart
	// fetches its own overrides directly).
	var (
		freshOverrides    map[string]any
		freshContentHash  string
		hasOverridesUpdate bool
	)
	if desired && running && hasOverlay && m.Overrides != nil {
		ov, h, err := m.Overrides.FetchOverrides(ctx)
		if err != nil {
			// Stale overrides are better than no service — record but
			// fall through to the report-ready branch.
			m.recordError("fetch_overrides", err)
		} else {
			freshOverrides = ov
			freshContentHash = h
			// First-tick-after-start has lastConfigHash="" — don't
			// trigger a restart on cold boot just because the platform
			// has overrides; the daemon already runs with whatever's
			// on disk.
			hasOverridesUpdate = m.state.lastConfigHash != "" &&
				freshContentHash != m.state.lastConfigHash
		}
	}

	switch {
	case !desired && running:
		m.transitionStop(ctx)
	case !desired && hasCert:
		m.transitionCleanupCert(ctx)
	case desired && !hasCert:
		m.transitionRequestCert(ctx)
	case desired && hasCert && !running && hasOverlay:
		m.transitionStart(ctx)
	case desired && hasCert && !running && !hasOverlay:
		m.recordError("waiting_overlay", errWaitingOverlay)
	case desired && running && hasOverlay && hasOverridesUpdate:
		m.transitionApplyConfigUpdate(ctx, freshOverrides, freshContentHash)
	case desired && running && hasOverlay:
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
	overrides, contentHash := m.fetchOverridesOrEmpty(ctx)
	cfg := DaemonConfig{
		ListenAddress: "tcp://[" + m.OverlayAddress + "]:2376",
		TLSCAPath:     m.Paths.CAFile,
		TLSCertPath:   m.Paths.CertFile,
		TLSKeyPath:    m.Paths.KeyFile,
		ExtraConfig:   overrides,
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
	m.state.lastConfigHash = contentHash    // baseline for change detection
	m.persistState()
}

// transitionApplyConfigUpdate fires when steady-state-running detects
// that operator daemon.json overrides have changed (slice 10). Writes
// the new merged config to disk and restarts dockerd to pick it up.
//
// Phase 1: full daemon restart on any change. Phase 2 may diff
// hot-reloadable keys (registry-mirrors, debug, log-level) and SIGHUP
// instead of stop+start to skip the ~3s restart window.
func (m *Manager) transitionApplyConfigUpdate(ctx context.Context,
	overrides map[string]any, contentHash string) {
	cfg := DaemonConfig{
		ListenAddress: "tcp://[" + m.OverlayAddress + "]:2376",
		TLSCAPath:     m.Paths.CAFile,
		TLSCertPath:   m.Paths.CertFile,
		TLSKeyPath:    m.Paths.KeyFile,
		ExtraConfig:   overrides,
	}
	if err := m.Applier.WriteDaemonConfig(ctx, cfg); err != nil {
		m.recordError("write_daemon_config_update", err)
		return
	}
	if err := m.Applier.StopDaemon(ctx); err != nil {
		// Best-effort — if the daemon is already stopped, StartDaemon
		// brings it back up. If it can't be stopped, StartDaemon
		// will likely fail too and we'll record that error instead.
		m.recordError("stop_daemon_for_config_update", err)
	}
	if err := m.Applier.StartDaemon(ctx); err != nil {
		m.recordError("start_daemon_for_config_update", err)
		return
	}
	m.state.lastConfigHash = contentHash
	// Force re-report on next tick — version may not have changed but
	// the platform should observe a fresh ready signal so operators
	// see the config-update transition in the activity feed.
	m.state.readyReportedFor = ""
	m.persistState()
}

// fetchOverridesOrEmpty calls m.Overrides if configured, returning
// empty values on any error so the caller can proceed with a base
// daemon.json. Used by transitionStart where missing overrides should
// not block daemon startup.
func (m *Manager) fetchOverridesOrEmpty(ctx context.Context) (map[string]any, string) {
	if m.Overrides == nil {
		return map[string]any{}, ""
	}
	overrides, hash, err := m.Overrides.FetchOverrides(ctx)
	if err != nil {
		// Non-fatal — record but proceed with empty overrides. The
		// next tick's running-state branch will re-fetch and pick up
		// any overrides if the failure was transient.
		m.recordError("fetch_overrides_on_start", err)
		return map[string]any{}, ""
	}
	if overrides == nil {
		overrides = map[string]any{}
	}
	return overrides, hash
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
	m.persistState()
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
	m.persistState()
}

func (m *Manager) transitionCleanupCert(ctx context.Context) {
	if err := m.Applier.RemoveCert(ctx); err != nil {
		m.recordError("remove_cert", err)
		return
	}
	m.state.readyReportedFor = ""
	m.state.stoppedReportedAt = time.Time{}
	m.persistState()
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

// SetOverlayAddress updates the daemon listen address that
// transitionStart / transitionReportReady will use. service.Run()
// calls this each tick (after the SDWAN reconciler has had a chance
// to populate the address) so the docker reconciler always sees
// fresh state. Safe to call concurrently with Reconcile — guarded
// by the same mutex.
func (m *Manager) SetOverlayAddress(addr string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.OverlayAddress = addr
}

// errMissingNodeID is the sentinel for misconfiguration — the agent
// should never construct a Manager without a NodeID, but defense in
// depth catches the bug at reconcile time instead of at first
// platform call.
var errMissingNodeID = sentinelError("dockerd Manager: NodeID required")

// errWaitingOverlay is recorded (non-fatal) when transitionStart would
// run but no overlay address is known yet. SDWAN reconciler runs
// ahead of dockerd in the PostSend chain, so this clears within one
// tick of SDWAN successfully fetching its config.
var errWaitingOverlay = sentinelError("waiting for SDWAN overlay address")

type sentinelError string

func (e sentinelError) Error() string { return string(e) }
