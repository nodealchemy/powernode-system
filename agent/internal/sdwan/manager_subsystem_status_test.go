// manager_subsystem_status_test.go — the wire contract for per-subsystem
// applier reporting (SubsystemStates) and for the measured healthy-peer
// count, both consumed by the platform's SDWAN fleet sensors.
//
// The property under test throughout is that a host running WITHOUT a
// subsystem the platform asked for cannot look green to a sensor. Three
// composing bugs used to guarantee the opposite: recordError dropped the
// label, Reconcile's tail cleared every error unconditionally, and the
// heartbeat payload was built before Reconcile ran, so it read a value the
// previous tick had already wiped.

package sdwan

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// ------------------------------------------------------------------
// Fakes
// ------------------------------------------------------------------

// fakeWgApplier reports one peer per interface. handshakeAge controls
// whether that peer classifies as active (<3m) or disconnected.
type fakeWgApplier struct {
	handshakeAge time.Duration
	readErr      error
	applyErr     error
	removed      []string
}

func (f *fakeWgApplier) ApplyInterface(ctx context.Context, cfg InterfaceConf, peers []PeerConf, privateKey string) error {
	return f.applyErr
}

func (f *fakeWgApplier) RemoveInterface(ctx context.Context, name string) error {
	f.removed = append(f.removed, name)
	return nil
}

func (f *fakeWgApplier) ReadActualState(ctx context.Context, name string) (*ActualInterfaceState, error) {
	if f.readErr != nil {
		return nil, f.readErr
	}
	return &ActualInterfaceState{
		Name: name,
		Peers: []ActualPeerState{
			{PublicKey: "PEERPUB-" + name, LastHandshakeAt: time.Now().Add(-f.handshakeAge)},
		},
	}, nil
}

func (f *fakeWgApplier) ListSdwanInterfaces(ctx context.Context) ([]string, error) {
	return nil, nil
}

// togglingApplier stands in for any applier whose failure we want to turn
// on and off between reconcile passes. failFor, when set, narrows the
// failure to a single network so sibling networks succeed in the same pass.
type togglingApplier struct {
	err     error
	failFor string
}

func (t *togglingApplier) ApplyRuleset(ctx context.Context, networkID string, fw *FirewallConf) error {
	if t.failFor != "" && t.failFor != networkID {
		return nil
	}
	return t.err
}

func (t *togglingApplier) RemoveChain(ctx context.Context, networkID string, fw *FirewallConf) error {
	return nil
}

type togglingNat struct{ err error }

func (t *togglingNat) ApplyRuleset(ctx context.Context, networkID string, nat *NatConf) error {
	return t.err
}

func (t *togglingNat) RemoveChain(ctx context.Context, networkID string, nat *NatConf) error {
	return nil
}

type togglingVrf struct{ err error }

func (t *togglingVrf) Apply(ctx context.Context, desired []DesiredVRF) error { return t.err }

// recordingOvnNb records every plan it is handed so a test can assert the
// applier is still CALLED for a nil/empty plan (that call is how it resets
// its replay cache) even though the outcome is not recorded as a success.
type recordingOvnNb struct {
	err   error
	calls int
	last  *OvnNbPlan
}

func (o *recordingOvnNb) Apply(ctx context.Context, plan *OvnNbPlan) (*ObservedOvnNbState, error) {
	o.calls++
	o.last = plan
	if o.err != nil {
		return nil, o.err
	}
	return &ObservedOvnNbState{}, nil
}

type togglingFrrObserver struct{ err error }

func (t *togglingFrrObserver) ObserveBgp(ctx context.Context, networkID string) (*ObservedBgpState, error) {
	if t.err != nil {
		return nil, t.err
	}
	return &ObservedBgpState{NetworkID: networkID}, nil
}

// noopFrrApplier lets a test populate iBgpNetworkIDs, which is what gates
// the whole BGP observation block.
type noopFrrApplier struct{}

func (noopFrrApplier) ApplyConfig(ctx context.Context, cfg *BgpConf) error { return nil }
func (noopFrrApplier) DisableFrr(ctx context.Context) error                { return nil }

// ------------------------------------------------------------------
// Harness
// ------------------------------------------------------------------

// networkJSON renders one network in the shape GET /config/sdwan returns.
// firewall/nat are included only when asked for, so a test can drop a
// subsystem's precondition mid-run.
func networkJSON(netID, iface string, firewall, nat bool) string {
	parts := []string{
		`"network_id":"` + netID + `"`,
		`"peer_id":"peer-` + netID + `"`,
		`"interface":{"name":"` + iface + `","address":"fd00::1/128","private_key":"k"}`,
		`"peers":[{"peer_id":"remote-` + netID + `","public_key":"PEERPUB-` + iface + `","allowed_ips":["fd00::2/128"]}]`,
	}
	if firewall {
		parts = append(parts, `"firewall":{"table":"powernode_sdwan","chain":"sdwan_`+netID+`","interface":"`+iface+`","policy":"drop","rule_count":3,"ruleset":"table inet powernode_sdwan {}"}`)
	}
	if nat {
		parts = append(parts, `"nat":{"table":"powernode_sdwan","chain":"sdwan_nat_`+netID+`","rule_count":1,"ruleset":"table inet powernode_sdwan {}"}`)
	}
	return "{" + strings.Join(parts, ",") + "}"
}

// testHarness serves a mutable desired config and hands back a Manager
// wired to it. Swap `config` between Reconcile calls to simulate the
// platform changing what it asks for.
type testHarness struct {
	mu sync.Mutex
	// configStatus, when non-zero, makes the config endpoint answer with
	// that HTTP status instead of the payload — the shape a control-plane
	// outage takes on the wire.
	configStatus int
	// bgpPostFails makes POST /status/bgp answer 500, which is the only
	// way to drive post_bgp_status into an error state.
	bgpPostFails bool
	config       string
	mgr          *Manager
	wg           *fakeWgApplier
	nft          *togglingApplier
	nat          *togglingNat
	vrf          *togglingVrf
	ovnNb        *recordingOvnNb
	bgpObs       *togglingFrrObserver
	labels       []string
}

func newHarness(t *testing.T, networks ...string) *testHarness {
	t.Helper()
	h := &testHarness{
		config: configJSON("", networks...),
		wg:     &fakeWgApplier{handshakeAge: 10 * time.Second},
		nft:    &togglingApplier{},
		nat:    &togglingNat{},
		vrf:    &togglingVrf{},
		ovnNb:  &recordingOvnNb{},
		bgpObs: &togglingFrrObserver{},
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost {
			h.mu.Lock()
			fail := h.bgpPostFails && strings.HasSuffix(r.URL.Path, "/status/bgp")
			h.mu.Unlock()
			if fail {
				w.WriteHeader(http.StatusInternalServerError)
				w.Write([]byte(`{"success":false,"error":"bgp status rejected"}`))
				return
			}
			w.Write([]byte(`{"success":true,"data":{}}`))
			return
		}
		h.mu.Lock()
		body, status := h.config, h.configStatus
		h.mu.Unlock()
		if status != 0 {
			w.WriteHeader(status)
			w.Write([]byte(`{"success":false,"error":"control plane unavailable"}`))
			return
		}
		w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)

	h.mgr = &Manager{
		Client:          transport.NewForTest(srv.URL, 5*time.Second),
		Applier:         h.wg,
		NftablesApplier: h.nft,
		NatApplier:      h.nat,
		VRFApplier:      h.vrf,
		OvnNbApplier:    h.ovnNb,
		// FrrObserver is wired, but the whole observation block is gated
		// on iBgpNetworkIDs, which only fills when FrrApplier is ALSO set
		// and a network has bgp.enabled. Tests that want it set both.
		FrrObserver: h.bgpObs,
		OnError: func(label string, err error) {
			h.mu.Lock()
			h.labels = append(h.labels, label)
			h.mu.Unlock()
		},
	}
	return h
}

// configJSON builds a /config/sdwan body. extraTopLevel carries host-scoped
// blocks that sit beside networks — constellations, ovn_nb_plan — so a test
// can add and remove a subsystem's subject between passes.
func configJSON(extraTopLevel string, networks ...string) string {
	data := `"instance_id":"inst-1","networks":[` + strings.Join(networks, ",") + `]`
	if extraTopLevel != "" {
		data += "," + extraTopLevel
	}
	return `{"success":true,"data":{` + data + `}}`
}

func (h *testHarness) setConfig(networks ...string) {
	h.setConfigWith("", networks...)
}

func (h *testHarness) setConfigWith(extraTopLevel string, networks ...string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.config = configJSON(extraTopLevel, networks...)
}

func (h *testHarness) reconcile() { h.mgr.Reconcile(context.Background()) }

// statusFor returns the heartbeat block for one network id.
func (h *testHarness) statusFor(t *testing.T, netID string) HeartbeatStatus {
	t.Helper()
	for _, s := range h.mgr.HeartbeatStatuses() {
		if s.NetworkID == netID {
			return s
		}
	}
	t.Fatalf("no sdwan_state entry for network %q", netID)
	return HeartbeatStatus{}
}

// findSubsystem returns the reported outcome for a subsystem/scope pair,
// and whether one was reported at all. The false return is the NOT
// MEASURED case and is never interchangeable with an "ok".
func findSubsystem(st HeartbeatStatus, subsystem, scope string) (SubsystemStatus, bool) {
	for _, s := range st.SubsystemStates {
		if s.Subsystem == subsystem && s.Scope == scope {
			return s, true
		}
	}
	return SubsystemStatus{}, false
}

func mustSubsystem(t *testing.T, st HeartbeatStatus, subsystem, scope string) SubsystemStatus {
	t.Helper()
	s, ok := findSubsystem(st, subsystem, scope)
	if !ok {
		t.Fatalf("no %s/%s entry in subsystem_states; got %+v", subsystem, scope, st.SubsystemStates)
	}
	return s
}

const (
	netA   = "net-aaaa1111"
	ifaceA = "wg-sdwan-aaaa1111"
	netB   = "net-bbbb2222"
	ifaceB = "wg-sdwan-bbbb2222"
)

// ------------------------------------------------------------------
// (a) a failing applier's error reaches the wire under its own label
// ------------------------------------------------------------------

func TestApplierFailureReachesHeartbeatUnderItsSubsystemLabel(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.nft.err = errors.New("nft -f: exit status 1 (ruleset REJECTED)")

	h.reconcile()

	st := h.statusFor(t, netA)
	got := mustSubsystem(t, st, "apply_firewall", netA)
	if got.State != SubsystemStateError {
		t.Errorf("apply_firewall state = %q, want %q", got.State, SubsystemStateError)
	}
	if !strings.Contains(got.Message, "ruleset REJECTED") {
		t.Errorf("apply_firewall message = %q, want the applier's error text", got.Message)
	}
	if got.ObservedAt == "" {
		t.Errorf("apply_firewall observed_at is empty; the sensor cannot age the report")
	}
	if _, err := time.Parse(time.RFC3339, got.ObservedAt); err != nil {
		t.Errorf("observed_at %q is not RFC3339: %v", got.ObservedAt, err)
	}
	if st.LastError == "" {
		t.Errorf("last_error is empty while a subsystem is failing")
	}
}

// The local log hook keeps firing with the same label it always did — the
// wire report is in addition to it, not instead of it.
func TestOnErrorHookStillReceivesTheLabel(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.nft.err = errors.New("nft rejected")

	h.reconcile()

	h.mu.Lock()
	defer h.mu.Unlock()
	for _, l := range h.labels {
		if l == "apply_firewall:"+netA {
			return
		}
	}
	t.Errorf("OnError never saw apply_firewall:%s; saw %v", netA, h.labels)
}

// A host-global applier's failure must be visible from every network, since
// a missing VRF is not one network's problem.
func TestHostGlobalFailureAppearsOnEveryNetwork(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true), networkJSON(netB, ifaceB, true, true))
	h.vrf.err = errors.New("ip link add vrf failed")

	h.reconcile()

	for _, id := range []string{netA, netB} {
		got := mustSubsystem(t, h.statusFor(t, id), "apply_vrfs", "")
		if got.State != SubsystemStateError {
			t.Errorf("network %s: apply_vrfs state = %q, want %q", id, got.State, SubsystemStateError)
		}
	}
}

// A network-scoped failure must NOT bleed onto a sibling network.
func TestNetworkScopedFailureStaysOnItsOwnNetwork(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true), networkJSON(netB, ifaceB, true, true))
	h.nft.err = errors.New("nft rejected")

	h.reconcile()

	if _, ok := findSubsystem(h.statusFor(t, netB), "apply_firewall", netA); ok {
		t.Errorf("network %s reported %s's apply_firewall outcome", netB, netA)
	}
	if got := mustSubsystem(t, h.statusFor(t, netB), "apply_firewall", netB); got.State != SubsystemStateError {
		t.Errorf("network %s: own apply_firewall should also be failing, got %q", netB, got.State)
	}
}

// The MC forwarding gate refuses to bring the tunnel up, which is exactly
// the case where a silent agent is most dangerous: the node carries no
// SDWAN data plane at all.
func TestMCValidationFailureReachesTheWire(t *testing.T) {
	// The network carries an MC envelope signed by a constellation this
	// verifier does not trust, so the gate refuses the tunnel.
	h := newHarness(t, strings.TrimSuffix(networkJSON(netA, ifaceA, true, true), "}")+
		`,"mc_envelope":{"envelope":"e30=","signature":"c2ln","constellation_handle":"untrusted"}}`)
	h.mgr.MCVerifier = NewMCVerifier()

	h.reconcile()

	st := h.statusFor(t, netA)
	if got := mustSubsystem(t, st, "mc_validate", netA); got.State != SubsystemStateError {
		t.Errorf("mc_validate state = %q, want %q", got.State, SubsystemStateError)
	}
	if st.HealthyPeers != nil {
		t.Errorf("healthy_peers = %d; the gate refused the tunnel, so nothing was measured", *st.HealthyPeers)
	}
}

func TestMissingMCIsReportedAndLeavesValidationNotMeasured(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.mgr.MCVerifier = NewMCVerifier()

	h.reconcile()

	st := h.statusFor(t, netA)
	if got := mustSubsystem(t, st, "mc_missing", netA); got.State != SubsystemStateError {
		t.Errorf("mc_missing state = %q, want %q", got.State, SubsystemStateError)
	}
	if got, ok := findSubsystem(st, "mc_validate", netA); ok {
		t.Errorf("mc_validate reports %q with no envelope to validate; want NOT MEASURED", got.State)
	}
}

// ------------------------------------------------------------------
// (b) the report survives the next heartbeat build
// ------------------------------------------------------------------

// Reconcile runs in Heartbeater.PostSend, i.e. AFTER Send() has already
// built the payload. So the value a heartbeat ships is always the one left
// behind by the PREVIOUS tick. Simulate exactly that ordering.
func TestFailureSurvivesTheFollowingHeartbeatBuild(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.nft.err = errors.New("nft rejected")

	h.reconcile() // tick 1 PostSend

	// tick 2: Send() builds the payload first...
	built := h.statusFor(t, netA)
	if got := mustSubsystem(t, built, "apply_firewall", netA); got.State != SubsystemStateError {
		t.Fatalf("tick 2 payload lost tick 1's failure: state = %q", got.State)
	}
	h.reconcile() // ...then PostSend reconciles again, still failing

	// tick 3 payload
	built = h.statusFor(t, netA)
	if got := mustSubsystem(t, built, "apply_firewall", netA); got.State != SubsystemStateError {
		t.Errorf("tick 3 payload lost the still-live failure: state = %q", got.State)
	}
}

// The end-of-pass bookkeeping must not wipe errors recorded during that
// same pass — the reconcile completes successfully overall even when an
// applier inside it failed.
func TestSuccessfulPassDoesNotWipeItsOwnApplierFailure(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.nft.err = errors.New("nft rejected")

	h.reconcile()

	st := h.statusFor(t, netA)
	if st.LastReconcileAt == "" {
		t.Fatalf("expected the pass to complete (last_reconcile_at set)")
	}
	if got := mustSubsystem(t, st, "apply_firewall", netA); got.State != SubsystemStateError {
		t.Errorf("a completed pass erased the failure it recorded: state = %q", got.State)
	}
}

// ------------------------------------------------------------------
// (c) the report clears when THAT subsystem next succeeds
// ------------------------------------------------------------------

func TestFailureClearsWhenThatSubsystemSucceeds(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.nft.err = errors.New("nft rejected")
	h.reconcile()
	if got := mustSubsystem(t, h.statusFor(t, netA), "apply_firewall", netA); got.State != SubsystemStateError {
		t.Fatalf("setup: expected a failure first, got %q", got.State)
	}

	h.nft.err = nil
	h.reconcile()

	st := h.statusFor(t, netA)
	got := mustSubsystem(t, st, "apply_firewall", netA)
	if got.State != SubsystemStateOK {
		t.Errorf("apply_firewall state = %q after a successful apply, want %q", got.State, SubsystemStateOK)
	}
	if got.Message != "" {
		t.Errorf("apply_firewall still carries the stale message %q", got.Message)
	}
	if st.LastError != "" {
		t.Errorf("last_error = %q with no subsystem failing", st.LastError)
	}
}

// ------------------------------------------------------------------
// (d) another subsystem's success does NOT clear it
// ------------------------------------------------------------------

func TestOtherSubsystemSuccessDoesNotClearAFailure(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.nft.err = errors.New("nft rejected")

	// apply_nat and apply_vrfs both succeed in the same pass, and
	// apply_nat runs AFTER apply_firewall on the same network.
	h.reconcile()
	h.reconcile()

	st := h.statusFor(t, netA)
	if got := mustSubsystem(t, st, "apply_nat", netA); got.State != SubsystemStateOK {
		t.Fatalf("setup: apply_nat should be succeeding, got %q", got.State)
	}
	if got := mustSubsystem(t, st, "apply_vrfs", ""); got.State != SubsystemStateOK {
		t.Fatalf("setup: apply_vrfs should be succeeding, got %q", got.State)
	}
	if got := mustSubsystem(t, st, "apply_firewall", netA); got.State != SubsystemStateError {
		t.Errorf("apply_firewall was cleared by a sibling subsystem's success: state = %q", got.State)
	}
}

// The network identity is part of the key, so the SAME subsystem
// succeeding on a sibling network must not clear the failure — netB's
// apply_firewall runs after netA's in the very same pass.
func TestSiblingNetworkSuccessDoesNotClearAFailure(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true), networkJSON(netB, ifaceB, true, true))
	h.nft.err = errors.New("nft rejected")
	h.nft.failFor = netA

	h.reconcile()

	if got := mustSubsystem(t, h.statusFor(t, netB), "apply_firewall", netB); got.State != SubsystemStateOK {
		t.Fatalf("setup: netB apply_firewall = %q, want ok", got.State)
	}
	if got := mustSubsystem(t, h.statusFor(t, netA), "apply_firewall", netA); got.State != SubsystemStateError {
		t.Errorf("netA apply_firewall = %q — netB's success cleared it", got.State)
	}
}

// A subsystem whose precondition disappears from the desired config goes
// back to NOT MEASURED rather than being reported as healthy.
func TestSubsystemWithNoPreconditionGoesBackToNotMeasured(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.nft.err = errors.New("nft rejected")
	h.reconcile()
	if got := mustSubsystem(t, h.statusFor(t, netA), "apply_firewall", netA); got.State != SubsystemStateError {
		t.Fatalf("setup: expected a failure first, got %q", got.State)
	}

	// The platform stops compiling a ruleset for this network.
	h.setConfig(networkJSON(netA, ifaceA, false, true))
	h.reconcile()

	if got, ok := findSubsystem(h.statusFor(t, netA), "apply_firewall", netA); ok {
		t.Errorf("netA has no compiled firewall but still reports apply_firewall = %q", got.State)
	}
}

// ------------------------------------------------------------------
// Oracle discipline: never-ran is distinguishable from succeeded
// ------------------------------------------------------------------

func TestNeverRunSubsystemIsAbsentNotOK(t *testing.T) {
	// No VipApplier, no FrrApplier, no MCVerifier are wired, so those
	// subsystems never run.
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.reconcile()

	st := h.statusFor(t, netA)
	for _, subsystem := range []string{"apply_vips", "apply_frr", "mc_validate"} {
		if got, ok := findSubsystem(st, subsystem, ""); ok {
			t.Errorf("%s never ran but reports state %q — a consumer would read that as healthy", subsystem, got.State)
		}
		if got, ok := findSubsystem(st, subsystem, netA); ok {
			t.Errorf("%s never ran but reports state %q", subsystem, got.State)
		}
	}
	// ...while a subsystem that DID run says so explicitly.
	if got := mustSubsystem(t, st, "apply_firewall", netA); got.State != SubsystemStateOK {
		t.Errorf("apply_firewall ran and succeeded but reports %q", got.State)
	}
}

// An "ok" is only ever written by an observed success, so an empty
// subsystem_states list means "nothing measured", not "all healthy".
func TestNoSubsystemsMeasuredYieldsNoGreenClaims(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, false, false))
	h.mgr.NftablesApplier = nil
	h.mgr.NatApplier = nil
	h.mgr.VRFApplier = nil
	h.reconcile()

	st := h.statusFor(t, netA)
	for _, s := range st.SubsystemStates {
		switch s.Subsystem {
		case "fetch_desired_config", "private_key_lookup", "apply_interface", "read_actual", "post_status":
			// These genuinely ran.
		default:
			t.Errorf("unexpected %q outcome for a subsystem that never ran: %+v", s.Subsystem, s)
		}
	}
}

// ------------------------------------------------------------------
// (e) HealthyPeers is written, and unknown differs from a measured zero
// ------------------------------------------------------------------

func TestHealthyPeersCountsActiveHandshakes(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.wg.handshakeAge = 10 * time.Second // inside the 3m active window
	h.reconcile()

	st := h.statusFor(t, netA)
	if st.HealthyPeers == nil {
		t.Fatalf("healthy_peers is nil after a pass that read the interface")
	}
	if *st.HealthyPeers != 1 {
		t.Errorf("healthy_peers = %d, want 1", *st.HealthyPeers)
	}
	if st.PeerCount != 1 {
		t.Errorf("peer_count = %d, want 1", st.PeerCount)
	}
}

func TestHealthyPeersMeasuredZeroIsNotUnknown(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.wg.handshakeAge = 30 * time.Minute // stale: peer is disconnected
	h.reconcile()

	st := h.statusFor(t, netA)
	if st.HealthyPeers == nil {
		t.Fatalf("healthy_peers is nil, but the interface WAS read — a measured zero must be reported as zero")
	}
	if *st.HealthyPeers != 0 {
		t.Errorf("healthy_peers = %d, want a measured 0", *st.HealthyPeers)
	}
}

func TestHealthyPeersUnknownWhenInterfaceNeverRead(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.wg.applyErr = errors.New("wg setconf failed") // pass never reaches ReadActualState
	h.reconcile()

	st := h.statusFor(t, netA)
	if st.HealthyPeers != nil {
		t.Errorf("healthy_peers = %d, want nil (NOT MEASURED) when the interface apply failed", *st.HealthyPeers)
	}
	if got := mustSubsystem(t, st, "apply_interface", ifaceA); got.State != SubsystemStateError {
		t.Errorf("apply_interface state = %q, want %q", got.State, SubsystemStateError)
	}
}

func TestHealthyPeersBecomesUnknownAgainWhenMeasurementStops(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.reconcile()
	if h.statusFor(t, netA).HealthyPeers == nil {
		t.Fatalf("setup: expected a measured count on the first pass")
	}

	h.wg.readErr = errors.New("wg show: No such device")
	h.reconcile()

	if got := h.statusFor(t, netA).HealthyPeers; got != nil {
		t.Errorf("healthy_peers = %d after the read failed; a stale count must decay to nil (unknown)", *got)
	}
}

// The JSON is the actual contract with the platform: unknown must be null,
// never a zero a sensor could read as "no unhealthy peers".
func TestHealthyPeersSerializesUnknownAsNull(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.wg.applyErr = errors.New("wg setconf failed")
	h.reconcile()

	raw, err := json.Marshal(h.statusFor(t, netA))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(raw), `"healthy_peers":null`) {
		t.Errorf("unknown healthy_peers did not serialize as null: %s", raw)
	}

	h.wg.applyErr = nil
	h.wg.handshakeAge = 30 * time.Minute
	h.reconcile()

	raw, err = json.Marshal(h.statusFor(t, netA))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(raw), `"healthy_peers":0`) {
		t.Errorf("measured zero healthy_peers did not serialize as 0: %s", raw)
	}
}

// ------------------------------------------------------------------
// Concurrency: the snapshot must not alias manager state
// ------------------------------------------------------------------

func TestHeartbeatStatusesReturnsAnIndependentCopy(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.nft.err = errors.New("nft rejected")
	h.reconcile()

	first := h.statusFor(t, netA)
	if first.HealthyPeers == nil || len(first.SubsystemStates) == 0 {
		t.Fatalf("setup: expected a populated status block")
	}

	*first.HealthyPeers = 9999
	for i := range first.SubsystemStates {
		first.SubsystemStates[i].State = "tampered"
		first.SubsystemStates[i].Message = "tampered"
	}

	second := h.statusFor(t, netA)
	if second.HealthyPeers == nil || *second.HealthyPeers == 9999 {
		t.Errorf("caller mutation of healthy_peers reached manager state")
	}
	for _, s := range second.SubsystemStates {
		if s.State == "tampered" || s.Message == "tampered" {
			t.Errorf("caller mutation of subsystem_states reached manager state: %+v", s)
		}
	}
	if got := mustSubsystem(t, second, "apply_firewall", netA); got.State != SubsystemStateError {
		t.Errorf("apply_firewall state = %q after tampering with an earlier snapshot", got.State)
	}
}

// Reconcile writes the maps while the heartbeat goroutine reads them. Run
// with -race to make this meaningful; it is a smoke test otherwise.
func TestConcurrentReconcileAndHeartbeatBuild(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true), networkJSON(netB, ifaceB, true, true))
	h.nft.err = errors.New("nft rejected")

	var wg sync.WaitGroup
	stop := make(chan struct{})

	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
				for _, s := range h.mgr.HeartbeatStatuses() {
					_ = s.SubsystemStates
					if s.HealthyPeers != nil {
						_ = *s.HealthyPeers
					}
				}
			}
		}
	}()

	for i := 0; i < 25; i++ {
		h.reconcile()
	}
	close(stop)
	wg.Wait()
}

// ------------------------------------------------------------------
// Housekeeping: a network the platform stopped sending must not leak
// ------------------------------------------------------------------

func TestOutcomesForARemovedNetworkAreDropped(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true), networkJSON(netB, ifaceB, true, true))
	h.nft.err = errors.New("nft rejected")
	h.reconcile()

	// Platform stops sending netA entirely.
	h.nft.err = nil
	h.setConfig(networkJSON(netB, ifaceB, true, true))
	h.reconcile()

	st := h.statusFor(t, netB)
	for _, s := range st.SubsystemStates {
		if s.Scope == netA || s.Scope == ifaceA {
			t.Errorf("removed network %s leaked onto %s as host-global: %+v", netA, netB, s)
		}
	}
	if st.LastError != "" {
		t.Errorf("last_error = %q, but the only failing network was removed", st.LastError)
	}
}

// A config-fetch failure is itself a subsystem and must persist until the
// fetch next succeeds, rather than being the only error the wire could ever
// carry.
func TestFetchFailureIsReportedAsASubsystemAndClears(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.reconcile()

	h.mu.Lock()
	h.configStatus = http.StatusInternalServerError
	h.mu.Unlock()
	h.reconcile()

	st := h.statusFor(t, netA)
	got := mustSubsystem(t, st, "fetch_desired_config", "")
	if got.State != SubsystemStateError {
		t.Errorf("fetch_desired_config state = %q, want %q", got.State, SubsystemStateError)
	}
	if st.LastError == "" {
		t.Errorf("last_error is empty while the config fetch is failing")
	}

	h.mu.Lock()
	h.configStatus = 0
	h.mu.Unlock()
	h.reconcile()

	if got := mustSubsystem(t, h.statusFor(t, netA), "fetch_desired_config", ""); got.State != SubsystemStateOK {
		t.Errorf("fetch_desired_config state = %q after a good fetch, want %q", got.State, SubsystemStateOK)
	}
}

// ------------------------------------------------------------------
// Corner subsystems: a no-op is not a success, and an unreachable label
// must still be able to return to NOT MEASURED
// ------------------------------------------------------------------

// networkWithBgpJSON renders a network carrying an iBGP config, which is
// what puts it into iBgpNetworkIDs and enables the observation block.
func networkWithBgpJSON(netID, iface string, bgpEnabled bool) string {
	enabled := "false"
	if bgpEnabled {
		enabled = "true"
	}
	return strings.TrimSuffix(networkJSON(netID, iface, true, true), "}") +
		`,"bgp":{"enabled":` + enabled + `,"as_number":65000,"router_id":"10.0.0.1"}}`
}

const ovnPlanJSON = `"ovn_nb_plan":{"deployment_id":"dep-1","nb_db_endpoint":"tcp:10.0.0.1:6641","plan":[{"cmd":"ls-add","args":["ls0"]}]}`

// FINDING 1. ShellOvnNbApplier returns (obs, nil) for a nil/empty plan
// WITHOUT executing anything. NewManager always wires it, so recording that
// as a success told every lightweight host that a subsystem it never ran
// was healthy — the exact false-green this whole change exists to prevent.
func TestOvnNbNoOpPlanIsAbsentNotOK(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true)) // no ovn_nb_plan
	h.reconcile()

	st := h.statusFor(t, netA)
	if got, ok := findSubsystem(st, "apply_ovn_nb_plan", ""); ok {
		t.Errorf("nil OVN plan reported apply_ovn_nb_plan = %q; a no-op that executed nothing is NOT MEASURED", got.State)
	}
	// The applier must still be CALLED — that call is how it resets its
	// last-endpoint/last-signature replay cache.
	if h.ovnNb.calls == 0 {
		t.Errorf("OvnNbApplier.Apply was skipped entirely; its cache-reset path never ran")
	}
}

// A former control host whose deployment is deleted must go from error to
// ABSENT, never to a no-op "ok".
func TestOvnNbErrorGoesToAbsentWhenPlanIsWithdrawn(t *testing.T) {
	h := newHarness(t)
	h.setConfigWith(ovnPlanJSON, networkJSON(netA, ifaceA, true, true))
	h.ovnNb.err = errors.New("ovn-nbctl: connection refused")
	h.reconcile()
	if got := mustSubsystem(t, h.statusFor(t, netA), "apply_ovn_nb_plan", ""); got.State != SubsystemStateError {
		t.Fatalf("setup: apply_ovn_nb_plan = %q, want error", got.State)
	}

	// Deployment deleted: the plan disappears from the config.
	h.ovnNb.err = nil
	h.setConfig(networkJSON(netA, ifaceA, true, true))
	h.reconcile()

	if got, ok := findSubsystem(h.statusFor(t, netA), "apply_ovn_nb_plan", ""); ok {
		t.Errorf("withdrawn OVN plan left apply_ovn_nb_plan = %q; want it absent", got.State)
	}
}

// A real plan that applies cleanly IS an observed success — the fix must
// not collapse everything to absent.
func TestOvnNbRealPlanStillReportsOK(t *testing.T) {
	h := newHarness(t)
	h.setConfigWith(ovnPlanJSON, networkJSON(netA, ifaceA, true, true))
	h.reconcile()

	if got := mustSubsystem(t, h.statusFor(t, netA), "apply_ovn_nb_plan", ""); got.State != SubsystemStateOK {
		t.Errorf("apply_ovn_nb_plan = %q for a non-empty plan that applied cleanly, want ok", got.State)
	}
}

// FINDING 2a. observe_bgp is scoped to a network that STAYS in the config,
// so the end-of-pass sweep keeps it. If BGP is then disabled the label is
// never re-run, and a one-off vtysh failure would report error on that
// network forever.
func TestObserveBgpReturnsToNotMeasuredWhenBgpDisabled(t *testing.T) {
	h := newHarness(t, networkWithBgpJSON(netA, ifaceA, true))
	h.mgr.FrrApplier = noopFrrApplier{}
	h.bgpObs.err = errors.New("vtysh: connection refused")
	h.reconcile()
	if got := mustSubsystem(t, h.statusFor(t, netA), "observe_bgp", netA); got.State != SubsystemStateError {
		t.Fatalf("setup: observe_bgp = %q, want error", got.State)
	}

	// Operator disables iBGP on the network; the network itself stays.
	h.setConfig(networkWithBgpJSON(netA, ifaceA, false))
	h.reconcile()

	st := h.statusFor(t, netA)
	if got, ok := findSubsystem(st, "observe_bgp", netA); ok {
		t.Errorf("observe_bgp = %q after BGP was disabled; want NOT MEASURED", got.State)
	}
	if st.LastError != "" {
		t.Errorf("last_error = %q, still fed by a subsystem that is no longer attempted", st.LastError)
	}
}

// FINDING 2b. post_bgp_status is HOST-GLOBAL, so a stuck error is reported
// on every network. Its forget used to sit inside the observer guard.
func TestPostBgpStatusClearsWhenIBgpDisabledFleetWide(t *testing.T) {
	h := newHarness(t, networkWithBgpJSON(netA, ifaceA, true))
	h.mgr.FrrApplier = noopFrrApplier{}
	h.bgpPostFails = true
	h.reconcile()
	if got := mustSubsystem(t, h.statusFor(t, netA), "post_bgp_status", ""); got.State != SubsystemStateError {
		t.Fatalf("setup: post_bgp_status = %q, want error", got.State)
	}

	// iBGP switched off everywhere: the observer block stops running.
	h.bgpPostFails = false
	h.setConfig(networkWithBgpJSON(netA, ifaceA, false))
	h.reconcile()

	if got, ok := findSubsystem(h.statusFor(t, netA), "post_bgp_status", ""); ok {
		t.Errorf("post_bgp_status = %q with iBGP disabled fleet-wide; want NOT MEASURED", got.State)
	}
}

// FINDING 2c. A constellation handle is not a network, so the sweep used to
// keep it forever: an unbounded leak, and — because a non-network scope is
// routed host-global — a removed handle's stale error was reported on every
// surviving network.
func TestRemovedConstellationIsReapedAndNotMisroutedHostGlobal(t *testing.T) {
	const handle = "constellation-alpha"
	h := newHarness(t)
	h.setConfigWith(
		`"constellations":[{"handle":"`+handle+`","public_key_b64":"!!not-base64!!"}]`,
		networkJSON(netA, ifaceA, true, true))
	h.mgr.MCVerifier = NewMCVerifier()
	h.reconcile()

	if got := mustSubsystem(t, h.statusFor(t, netA), "trust_constellation", handle); got.State != SubsystemStateError {
		t.Fatalf("setup: trust_constellation = %q, want error", got.State)
	}

	// The constellation is de-trusted: the handle leaves the config.
	h.setConfig(networkJSON(netA, ifaceA, true, true))
	h.reconcile()

	st := h.statusFor(t, netA)
	for _, s := range st.SubsystemStates {
		if s.Subsystem == "trust_constellation" {
			t.Errorf("de-trusted handle survived the sweep and is reported host-global: %+v", s)
		}
	}
	// Wiring an MCVerifier also arms the MC gate, which legitimately fails
	// here (these fixtures carry no envelope), so last_error is expected to
	// be non-empty — it just must not still be the constellation's.
	if strings.Contains(st.LastError, "constellation public key") {
		t.Errorf("last_error = %q, still fed by the de-trusted constellation", st.LastError)
	}
}

// The reap must be restricted to scope kinds the config enumerates. A
// bridge index is a discriminator the config never contains, so a blanket
// "scope not in the config" reap would delete it every pass.
func TestIndexedBridgeOutcomeSurvivesTheSweep(t *testing.T) {
	h := newHarness(t, networkJSON(netA, ifaceA, true, true))
	h.mgr.BridgeAppliers = []BridgeApplier{&togglingBridge{err: errors.New("brctl addbr failed")}}

	h.reconcile()
	h.reconcile() // a second pass is where an over-broad sweep would strike

	if got := mustSubsystem(t, h.statusFor(t, netA), "apply_bridges", "0"); got.State != SubsystemStateError {
		t.Errorf("apply_bridges[0] = %q after a second pass; the sweep ate a live report", got.State)
	}
}

type togglingBridge struct{ err error }

func (t *togglingBridge) Apply(ctx context.Context, desired []DesiredBridge) error { return t.err }

// The label carries the discriminator the call site appended; the wire has
// to split it back apart so a sensor can group by subsystem.
func TestSplitSubsystemLabel(t *testing.T) {
	cases := []struct{ label, subsystem, scope string }{
		{"apply_vrfs", "apply_vrfs", ""},
		{"apply_firewall:net-abcd1234", "apply_firewall", "net-abcd1234"},
		{"apply_interface:wg-sdwan-abcd1234", "apply_interface", "wg-sdwan-abcd1234"},
		{"apply_bridges[0]", "apply_bridges", "0"},
		{"apply_bridges[11]", "apply_bridges", "11"},
		{"trust_constellation:handle", "trust_constellation", "handle"},
	}
	for _, c := range cases {
		sub, scope := splitSubsystemLabel(c.label)
		if sub != c.subsystem || scope != c.scope {
			t.Errorf("splitSubsystemLabel(%q) = (%q, %q), want (%q, %q)", c.label, sub, scope, c.subsystem, c.scope)
		}
	}
}
