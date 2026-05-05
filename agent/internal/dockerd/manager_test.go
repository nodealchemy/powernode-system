package dockerd

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

// stubApplier is the in-memory DaemonApplier used by all state-machine
// tests. Records each call so assertions verify both ordering and
// idempotency. Methods take/return what the real shell-out impl will
// — same contract, different storage.
type stubApplier struct {
	mu sync.Mutex

	// Storage
	Cert        *CertMaterial
	Config      *DaemonConfig
	Running     bool
	Version     string
	HasCertErr  error
	IsRunErr    error
	WriteErr    error
	StartErr    error
	StopErr     error

	// Call counters
	HasCertCalls   int
	WriteCertCalls int
	RemoveCertCalls int
	WriteCfgCalls  int
	StartCalls     int
	StopCalls      int
	VersionCalls   int
}

func (s *stubApplier) HasCert(_ context.Context) (bool, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.HasCertCalls++
	if s.HasCertErr != nil {
		return false, s.HasCertErr
	}
	return s.Cert != nil, nil
}

func (s *stubApplier) WriteCert(_ context.Context, m CertMaterial) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.WriteCertCalls++
	if s.WriteErr != nil {
		return s.WriteErr
	}
	s.Cert = &m
	return nil
}

func (s *stubApplier) RemoveCert(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.RemoveCertCalls++
	s.Cert = nil
	return nil
}

func (s *stubApplier) WriteDaemonConfig(_ context.Context, cfg DaemonConfig) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.WriteCfgCalls++
	c := cfg
	s.Config = &c
	return nil
}

func (s *stubApplier) IsDaemonRunning(_ context.Context) (bool, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	if s.IsRunErr != nil {
		return false, s.IsRunErr
	}
	return s.Running, nil
}

func (s *stubApplier) StartDaemon(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.StartCalls++
	if s.StartErr != nil {
		return s.StartErr
	}
	s.Running = true
	return nil
}

func (s *stubApplier) StopDaemon(_ context.Context) error {
	s.mu.Lock(); defer s.mu.Unlock()
	s.StopCalls++
	if s.StopErr != nil {
		return s.StopErr
	}
	s.Running = false
	return nil
}

func (s *stubApplier) DaemonVersion(_ context.Context) (string, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.VersionCalls++
	return s.Version, nil
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

// fakePlatform stands up an httptest server that mirrors the platform
// runtime/handshake endpoint. Tracks calls so tests can assert exact
// state transitions (e.g. "ReportReady was called once with version
// 25.0.3").
type fakePlatform struct {
	server *httptest.Server

	mu        sync.Mutex
	WantsCert int
	Ready     int
	Stopped   int
	LastReady HandshakeRequest
}

func newFakePlatform(t *testing.T) *fakePlatform {
	t.Helper()
	fp := &fakePlatform{}
	fp.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		_ = json.Unmarshal(body, &req)

		fp.mu.Lock()
		switch req.Phase {
		case PhaseWantsCert:
			fp.WantsCert++
			fp.respond(w, map[string]any{
				"certificate": map[string]any{
					"cert_pem":     "-----BEGIN CERTIFICATE-----\nfake-leaf\n-----END CERTIFICATE-----",
					"ca_chain_pem": "-----BEGIN CERTIFICATE-----\nfake-ca\n-----END CERTIFICATE-----",
					"serial":       "ABCDEF",
					"not_after":    "2026-08-04T18:00:00Z",
				},
			})
		case PhaseReady:
			fp.Ready++
			fp.LastReady = req
			fp.respond(w, map[string]any{
				"host_id":      "h-1",
				"host_status":  "connected",
				"api_endpoint": "tcp://[fd00::1]:2376",
			})
		case PhaseStopped:
			fp.Stopped++
			fp.respond(w, map[string]any{
				"acknowledged": true,
				"host_id":      "h-1",
			})
		}
		fp.mu.Unlock()
	}))
	return fp
}

func (fp *fakePlatform) respond(w http.ResponseWriter, data map[string]any) {
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "data": data})
}

func (fp *fakePlatform) close() { fp.server.Close() }

func (fp *fakePlatform) client() *Client {
	return NewClient(&transport.Client{Client: fp.server.Client(), PlatformURL: fp.server.URL})
}

// newTestManager wires together stubs + a fake platform. NodeID and
// OverlayAddress are set to deterministic values so tests can assert
// against literal strings.
func newTestManager(t *testing.T, modules []string, applier *stubApplier) (*Manager, *fakePlatform, *stubModulesAPI) {
	t.Helper()
	fp := newFakePlatform(t)
	mods := &stubModulesAPI{Modules: modules}

	errLog := func(stage string, err error) {
		t.Logf("[Manager] %s: %v", stage, err)
	}
	m := NewManager(fp.client(), mods, applier, "node-1", "fd00::1", errLog)
	return m, fp, mods
}

// ────────────────────────────────────────────────────────────────────
// State-machine tests — one per branch of Reconcile, plus combined
// multi-tick scenarios that exercise idempotency.
// ────────────────────────────────────────────────────────────────────

func TestReconcile_Branch1_AssignedNoCert_RequestsCert(t *testing.T) {
	a := &stubApplier{}
	m, fp, _ := newTestManager(t, []string{"docker-engine", "system-base"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if fp.WantsCert != 1 {
		t.Fatalf("expected 1 wants_cert call, got %d", fp.WantsCert)
	}
	if a.Cert == nil || a.Cert.ServerCertPEM == "" {
		t.Fatalf("expected cert persisted, got %+v", a.Cert)
	}
	if a.WriteCertCalls != 1 {
		t.Fatalf("expected WriteCert called once, got %d", a.WriteCertCalls)
	}
}

func TestReconcile_Branch2_AssignedCertPresent_StartsDaemon(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.WriteCfgCalls != 1 {
		t.Fatalf("expected WriteDaemonConfig once, got %d", a.WriteCfgCalls)
	}
	if a.Config.ListenAddress != "tcp://[fd00::1]:2376" {
		t.Fatalf("ListenAddress: %q", a.Config.ListenAddress)
	}
	if a.StartCalls != 1 {
		t.Fatalf("expected StartDaemon once, got %d", a.StartCalls)
	}
	// We don't ReportReady on the same tick; daemon may still be
	// initializing. Next tick will see it running and fire ready.
	if fp.Ready != 0 {
		t.Fatalf("expected Ready=0 on start tick, got %d", fp.Ready)
	}
}

func TestReconcile_Branch3_AssignedRunning_ReportsReady(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if fp.Ready != 1 {
		t.Fatalf("expected ReportReady once, got %d", fp.Ready)
	}
	if fp.LastReady.Version != "25.0.3" {
		t.Fatalf("version not propagated: %q", fp.LastReady.Version)
	}
	if fp.LastReady.ListenAddress != "tcp://[fd00::1]:2376" {
		t.Fatalf("listen_address: %q", fp.LastReady.ListenAddress)
	}
}

func TestReconcile_Branch4_NotAssignedRunning_StopsAndReports(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	m, fp, _ := newTestManager(t, []string{"system-base"}, a) // no docker-engine
	defer fp.close()

	m.Reconcile(context.Background())

	if a.StopCalls != 1 {
		t.Fatalf("expected StopDaemon once, got %d", a.StopCalls)
	}
	if fp.Stopped != 1 {
		t.Fatalf("expected ReportStopped once, got %d", fp.Stopped)
	}
}

func TestReconcile_Branch5_NotAssignedCertPresent_RemovesCert(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}, Running: false}
	m, fp, _ := newTestManager(t, []string{}, a)
	defer fp.close()

	m.Reconcile(context.Background())

	if a.RemoveCertCalls != 1 {
		t.Fatalf("expected RemoveCert once, got %d", a.RemoveCertCalls)
	}
	if a.Cert != nil {
		t.Fatalf("expected cert cleared, got %+v", a.Cert)
	}
}

func TestReconcile_SteadyState_NoOps(t *testing.T) {
	a := &stubApplier{}
	m, fp, _ := newTestManager(t, []string{}, a) // not assigned, no cert, not running
	defer fp.close()

	m.Reconcile(context.Background())

	if a.WriteCertCalls > 0 || a.WriteCfgCalls > 0 ||
		a.StartCalls > 0 || a.StopCalls > 0 || a.RemoveCertCalls > 0 ||
		fp.WantsCert > 0 || fp.Ready > 0 || fp.Stopped > 0 {
		t.Fatalf("steady state should be no-op, got applier=%+v fp=%+v", a, fp)
	}
}

// Multi-tick: simulate the full provisioning lifecycle (3 ticks):
//   T1: cert request
//   T2: write config + start
//   T3: report ready
// Then re-tick — should be no-op (idempotent).
func TestReconcile_FullLifecycle_3Ticks(t *testing.T) {
	a := &stubApplier{Version: "25.0.3"}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()

	// T1: no cert → request_cert
	m.Reconcile(context.Background())
	if fp.WantsCert != 1 || a.Cert == nil {
		t.Fatalf("T1: expected cert acquired, got fp=%+v cert=%+v", fp, a.Cert)
	}

	// T2: cert now present, daemon not running → start
	m.Reconcile(context.Background())
	if a.StartCalls != 1 || !a.Running {
		t.Fatalf("T2: expected daemon started, got starts=%d running=%v", a.StartCalls, a.Running)
	}

	// T3: cert present + running → report ready
	m.Reconcile(context.Background())
	if fp.Ready != 1 {
		t.Fatalf("T3: expected ready reported, got %d", fp.Ready)
	}

	// T4: steady state — should NOT re-report ready
	m.Reconcile(context.Background())
	if fp.Ready != 1 {
		t.Fatalf("T4: ready should be idempotent, got %d", fp.Ready)
	}
}

// Idempotency: multiple ticks while in "report ready" state should
// only trigger one ReportReady POST.
func TestReconcile_ReportReady_Idempotent(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()

	for i := 0; i < 5; i++ {
		m.Reconcile(context.Background())
	}
	if fp.Ready != 1 {
		t.Fatalf("expected exactly 1 ReportReady call across 5 ticks, got %d", fp.Ready)
	}
}

// Version change: re-reports ready when daemon version updates (e.g.
// after operator upgrades dockerd). The state cache keys on version,
// so a change clears the dedup.
func TestReconcile_ReportReady_RefiredOnVersionChange(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()

	m.Reconcile(context.Background())
	if fp.Ready != 1 {
		t.Fatalf("first tick should report 25.0.3, got %d", fp.Ready)
	}

	a.Version = "25.0.4"
	m.Reconcile(context.Background())
	if fp.Ready != 2 {
		t.Fatalf("version change should re-fire ReportReady, got %d", fp.Ready)
	}
	if fp.LastReady.Version != "25.0.4" {
		t.Fatalf("expected last reported version 25.0.4, got %q", fp.LastReady.Version)
	}
}

// Stop is idempotent: multiple ticks with daemon running but module
// unassigned should only fire ReportStopped once (and stop the daemon
// once via the IsDaemonRunning gate).
func TestReconcile_Stop_Idempotent(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
	}
	m, fp, _ := newTestManager(t, []string{}, a)
	defer fp.close()

	m.Reconcile(context.Background()) // T1: stop + report stopped
	m.Reconcile(context.Background()) // T2: cert still present + not running → cleanup cert
	m.Reconcile(context.Background()) // T3: nothing assigned, no cert → no-op

	if fp.Stopped != 1 {
		t.Fatalf("ReportStopped should fire exactly once across 3 ticks, got %d", fp.Stopped)
	}
	if a.RemoveCertCalls != 1 {
		t.Fatalf("RemoveCert should fire exactly once, got %d", a.RemoveCertCalls)
	}
}

// Error in module list shouldn't crash, just record + return.
func TestReconcile_ModulesError_Recorded(t *testing.T) {
	a := &stubApplier{}
	m, fp, mods := newTestManager(t, nil, a)
	mods.Err = errors.New("network down")
	defer fp.close()

	m.Reconcile(context.Background())

	if m.LastError() == nil {
		t.Fatal("expected LastError to be recorded")
	}
	// Nothing should have been touched on the applier or platform.
	if a.HasCertCalls > 0 || fp.WantsCert > 0 {
		t.Fatalf("expected no progress past modules error")
	}
}

// Empty OverlayAddress while a daemon-start would otherwise fire
// should record a non-fatal "waiting" error and skip the start.
// Cert-request can still proceed because it doesn't depend on the
// listen address.
func TestReconcile_NoOverlay_DefersStart(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}, Running: false}
	fp := newFakePlatform(t)
	defer fp.close()
	m := NewManager(fp.client(), &stubModulesAPI{Modules: []string{"docker-engine"}}, a,
		"node-1", "", func(string, error) {}) // empty overlay

	m.Reconcile(context.Background())

	if a.StartCalls > 0 {
		t.Fatalf("expected start deferred when overlay empty, got starts=%d", a.StartCalls)
	}
	if m.LastError() == nil || m.LastError().Error() != "waiting for SDWAN overlay address" {
		t.Fatalf("expected waiting_overlay error, got %v", m.LastError())
	}
}

func TestReconcile_NoOverlay_AllowsCertRequest(t *testing.T) {
	a := &stubApplier{} // no cert, no daemon
	fp := newFakePlatform(t)
	defer fp.close()
	m := NewManager(fp.client(), &stubModulesAPI{Modules: []string{"docker-engine"}}, a,
		"node-1", "", func(string, error) {}) // empty overlay

	m.Reconcile(context.Background())

	if fp.WantsCert != 1 {
		t.Fatalf("expected cert request despite empty overlay, got %d", fp.WantsCert)
	}
}

func TestSetOverlayAddress_PromotesNextReconcile(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}, Running: false}
	fp := newFakePlatform(t)
	defer fp.close()
	m := NewManager(fp.client(), &stubModulesAPI{Modules: []string{"docker-engine"}}, a,
		"node-1", "", func(string, error) {})

	// First tick: overlay empty → no start.
	m.Reconcile(context.Background())
	if a.StartCalls != 0 {
		t.Fatalf("T1: expected no start, got %d", a.StartCalls)
	}

	// SDWAN reconciles, populates overlay address.
	m.SetOverlayAddress("fd00::42")

	// Second tick: overlay now populated → start fires.
	m.Reconcile(context.Background())
	if a.StartCalls != 1 {
		t.Fatalf("T2: expected start after overlay set, got %d", a.StartCalls)
	}
	if a.Config.ListenAddress != "tcp://[fd00::42]:2376" {
		t.Fatalf("expected updated listen address, got %q", a.Config.ListenAddress)
	}
}

// Missing NodeID is a config error — should record and bail without
// touching anything else.
func TestReconcile_MissingNodeID_Errors(t *testing.T) {
	a := &stubApplier{}
	fp := newFakePlatform(t)
	defer fp.close()
	m := NewManager(fp.client(), &stubModulesAPI{Modules: []string{"docker-engine"}}, a, "", "fd00::1",
		func(string, error) {})

	m.Reconcile(context.Background())

	if m.LastError() == nil {
		t.Fatal("expected error for missing NodeID")
	}
	if a.HasCertCalls > 0 {
		t.Fatal("expected NodeID guard to short-circuit before any applier call")
	}
}

// ────────────────────────────────────────────────────────────────────
// Slice 10 — operator daemon.json overrides + restart-on-change
// ────────────────────────────────────────────────────────────────────

// stubOverridesAPI returns a fixed override map + content_hash. The
// Calls counter lets tests assert how many fetches happened across
// reconcile ticks.
type stubOverridesAPI struct {
	mu          sync.Mutex
	Overrides   map[string]any
	ContentHash string
	Err         error
	Calls       int
}

func (s *stubOverridesAPI) FetchOverrides(_ context.Context) (map[string]any, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.Calls++
	if s.Err != nil {
		return nil, "", s.Err
	}
	return s.Overrides, s.ContentHash, nil
}

func (s *stubOverridesAPI) Set(o map[string]any, hash string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.Overrides = o
	s.ContentHash = hash
}

// On daemon start, the manager fetches overrides and stamps lastConfigHash
// for change detection on subsequent ticks. The DaemonConfig passed to
// the applier carries the operator overrides as ExtraConfig.
func TestReconcile_Slice10_StartFetchesOverrides(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}}
	overrides := &stubOverridesAPI{
		Overrides: map[string]any{
			"registry-mirrors": []any{"https://mirror.gcr.io"},
			"log-driver":       "journald",
		},
		ContentHash: "sha256-initial",
	}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	m.Overrides = overrides

	m.Reconcile(context.Background())

	if overrides.Calls != 1 {
		t.Fatalf("expected 1 overrides fetch on start, got %d", overrides.Calls)
	}
	if a.Config == nil || a.Config.ExtraConfig == nil {
		t.Fatal("expected ExtraConfig populated in DaemonConfig")
	}
	if a.Config.ExtraConfig["log-driver"] != "journald" {
		t.Fatalf("ExtraConfig missing log-driver, got %v", a.Config.ExtraConfig)
	}
	if m.state.lastConfigHash != "sha256-initial" {
		t.Fatalf("lastConfigHash not stamped: got %q", m.state.lastConfigHash)
	}
}

// When overrides change in steady-state-running, the manager must
// restart the daemon (Stop+Start) and write the new config.
func TestReconcile_Slice10_OverrideChange_TriggersRestart(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	overrides := &stubOverridesAPI{
		Overrides:   map[string]any{"log-driver": "json-file"},
		ContentHash: "sha256-v1",
	}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	m.Overrides = overrides

	// Prime: simulate a prior apply so lastConfigHash is set.
	m.state.lastConfigHash = "sha256-v1"
	m.state.readyReportedFor = "25.0.3"

	// Operator changes overrides — new content_hash.
	overrides.Set(map[string]any{"log-driver": "journald"}, "sha256-v2")

	startBefore := a.StartCalls
	stopBefore := a.StopCalls
	cfgBefore := a.WriteCfgCalls

	m.Reconcile(context.Background())

	if a.StopCalls != stopBefore+1 {
		t.Fatalf("expected StopDaemon once, got %d (before %d)", a.StopCalls, stopBefore)
	}
	if a.StartCalls != startBefore+1 {
		t.Fatalf("expected StartDaemon once, got %d (before %d)", a.StartCalls, startBefore)
	}
	if a.WriteCfgCalls != cfgBefore+1 {
		t.Fatalf("expected WriteDaemonConfig once, got %d (before %d)", a.WriteCfgCalls, cfgBefore)
	}
	if m.state.lastConfigHash != "sha256-v2" {
		t.Fatalf("lastConfigHash not advanced: got %q", m.state.lastConfigHash)
	}
	if m.state.readyReportedFor != "" {
		t.Fatalf("readyReportedFor should be cleared on config update, got %q", m.state.readyReportedFor)
	}
}

// When the override hash matches lastConfigHash, no restart occurs;
// the steady-state ReportReady path runs as usual.
func TestReconcile_Slice10_NoChange_NoRestart(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	overrides := &stubOverridesAPI{
		Overrides:   map[string]any{"log-driver": "journald"},
		ContentHash: "sha256-stable",
	}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	m.Overrides = overrides

	m.state.lastConfigHash = "sha256-stable"

	m.Reconcile(context.Background())

	if a.StartCalls != 0 {
		t.Fatalf("expected no start (steady state), got %d", a.StartCalls)
	}
	if a.StopCalls != 0 {
		t.Fatalf("expected no stop (steady state), got %d", a.StopCalls)
	}
	if a.WriteCfgCalls != 0 {
		t.Fatalf("expected no config write (no change), got %d", a.WriteCfgCalls)
	}
	if fp.Ready != 1 {
		t.Fatalf("expected ReportReady to run as usual, got %d", fp.Ready)
	}
}

// First tick after agent boot — daemon is already running (state cache
// missing or stale) but lastConfigHash="" because we don't know what was
// applied. Manager MUST NOT restart on this tick; trust whatever's on
// disk and stamp the hash for future change detection.
func TestReconcile_Slice10_FirstTickAfterBoot_NoRestart(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	overrides := &stubOverridesAPI{
		Overrides:   map[string]any{"log-driver": "journald"},
		ContentHash: "sha256-platform-current",
	}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	m.Overrides = overrides

	// lastConfigHash is empty (cold-boot or cache wipe).
	if m.state.lastConfigHash != "" {
		t.Fatalf("precondition: lastConfigHash should be empty, got %q", m.state.lastConfigHash)
	}

	m.Reconcile(context.Background())

	if a.StopCalls != 0 || a.StartCalls != 0 {
		t.Fatalf("expected NO restart on first tick (cold-boot guard), got stop=%d start=%d",
			a.StopCalls, a.StartCalls)
	}
	if fp.Ready != 1 {
		t.Fatalf("expected ReportReady to fire normally, got %d", fp.Ready)
	}
}

// When the OverridesAPI errors transiently, the manager records the
// error but proceeds with the steady-state path. Stale overrides are
// better than no service.
func TestReconcile_Slice10_OverridesError_FallsThrough(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	overrides := &stubOverridesAPI{
		Err: errors.New("transient platform error"),
	}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	m.Overrides = overrides

	m.state.lastConfigHash = "sha256-prior"

	m.Reconcile(context.Background())

	if a.StopCalls != 0 || a.StartCalls != 0 {
		t.Fatal("expected no restart when overrides fetch fails")
	}
	if fp.Ready != 1 {
		t.Fatalf("expected ReportReady to still fire, got %d", fp.Ready)
	}
	if m.LastError() == nil {
		t.Fatal("expected error to be recorded")
	}
}

// Backward compat — managers constructed without an Overrides API
// (existing callers, agent code paths that haven't migrated yet) must
// keep working as if no operator overrides existed.
func TestReconcile_Slice10_NilOverridesAPI_Compat(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	// m.Overrides intentionally nil

	m.Reconcile(context.Background())

	if a.StartCalls != 1 {
		t.Fatalf("expected start to fire normally with nil Overrides, got %d", a.StartCalls)
	}
	if a.Config.ExtraConfig == nil {
		t.Fatal("expected empty ExtraConfig map (not nil) for cleaner downstream code")
	}
	if len(a.Config.ExtraConfig) != 0 {
		t.Fatalf("expected empty ExtraConfig, got %v", a.Config.ExtraConfig)
	}
}
