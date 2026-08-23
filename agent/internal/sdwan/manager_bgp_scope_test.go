// manager_bgp_scope_test.go — IMP-2f34679b6b73.
//
// The manager is where a network id turns into an observation. It used to
// hand the observer nothing but the id, so every network on a host got the
// same host-wide answer under a different label. These tests pin the two
// properties that fix has to hold: the poll carries a routing context, and
// an observation the observer could not attribute never stands as a green
// subsystem outcome.

package sdwan

import (
	"context"
	"errors"
	"strings"
	"testing"
)

const (
	vrfA = "pnv-aaaa1111"
	vrfB = "pnv-bbbb2222"
)

func twoIbgpNetworks() []string {
	return []string{
		networkWithBgpAndVrfJSON(netA, ifaceA, true, vrfA),
		networkWithBgpAndVrfJSON(netB, ifaceB, true, vrfB),
	}
}

// Each network's poll must name ITS OWN VRF. Two networks sharing one scope
// is the misattribution, restated at the seam that produces it.
func TestManagerScopesEachNetworksObservationToItsOwnVrf(t *testing.T) {
	h := newHarness(t, twoIbgpNetworks()...)
	h.mgr.FrrApplier = noopFrrApplier{}

	h.reconcile()

	if len(h.bgpObs.scopes) != 2 {
		t.Fatalf("observer called with %d scopes, want one per iBGP network: %+v", len(h.bgpObs.scopes), h.bgpObs.scopes)
	}
	byNetwork := map[string]BgpObservationScope{}
	for _, s := range h.bgpObs.scopes {
		byNetwork[s.NetworkID] = s
	}
	if got := byNetwork[netA].VrfName; got != vrfA {
		t.Errorf("network %s polled with vrf %q, want %q", netA, got, vrfA)
	}
	if got := byNetwork[netB].VrfName; got != vrfB {
		t.Errorf("network %s polled with vrf %q, want %q", netB, got, vrfB)
	}
	for nid, s := range byNetwork {
		if s.SoleIbgpNetwork {
			t.Errorf("network %s reported as the host's only iBGP network; there are two", nid)
		}
	}
}

// A host with one iBGP network is told so, which is what keeps it reporting
// when its VRF assignment has not landed yet instead of going dark.
func TestManagerMarksASingleIbgpNetworkAsSole(t *testing.T) {
	h := newHarness(t, networkWithBgpAndVrfJSON(netA, ifaceA, true, ""))
	h.mgr.FrrApplier = noopFrrApplier{}

	h.reconcile()

	if len(h.bgpObs.scopes) != 1 {
		t.Fatalf("observer called with %d scopes, want 1: %+v", len(h.bgpObs.scopes), h.bgpObs.scopes)
	}
	if !h.bgpObs.scopes[0].SoleIbgpNetwork {
		t.Errorf("SoleIbgpNetwork = false on a host with exactly one iBGP network")
	}
}

// unattributableObserver is the shape a real ShellFrrObserver takes when FRR
// answered for a context it could not confirm: no sessions, and a reason.
type unattributableObserver struct {
	unattributable map[string]bool
	scopes         []BgpObservationScope
}

func (o *unattributableObserver) ObserveBgp(ctx context.Context, scope BgpObservationScope) (*ObservedBgpState, error) {
	o.scopes = append(o.scopes, scope)
	if o.unattributable[scope.NetworkID] {
		return &ObservedBgpState{
			NetworkID: scope.NetworkID, VrfName: scope.VrfName,
			Measured: false, NotMeasuredReason: NotMeasuredVrfScopeMismatch,
		}, nil
	}
	return &ObservedBgpState{
		NetworkID: scope.NetworkID, VrfName: scope.VrfName, Measured: true,
		Sessions: []ObservedBgpSession{{NeighborAddress: "fd00::2", State: "established"}},
	}, nil
}

// An unattributable observation is POSTED (the platform records why) but must
// not stand as an `ok` subsystem outcome: NOT MEASURED and ok are never
// interchangeable, which is the invariant the rest of this package's
// subsystem reporting is built on.
func TestUnattributableObservationIsPostedButNotReportedOK(t *testing.T) {
	h := newHarness(t, twoIbgpNetworks()...)
	h.mgr.FrrApplier = noopFrrApplier{}
	obs := &unattributableObserver{unattributable: map[string]bool{netB: true}}
	h.mgr.FrrObserver = obs

	h.reconcile()

	if got, ok := findSubsystem(h.statusFor(t, netB), "observe_bgp", netB); ok {
		t.Errorf("observe_bgp/%s = %q for an observation that could not be attributed; want NOT MEASURED",
			netB, got.State)
	}
	if got := mustSubsystem(t, h.statusFor(t, netA), "observe_bgp", netA); got.State != SubsystemStateOK {
		t.Errorf("observe_bgp/%s = %q; the attributable network should still report ok", netA, got.State)
	}

	body := h.lastBgpPost(t)
	if !strings.Contains(body, `"measured":false`) {
		t.Errorf("POST /status/bgp body carries no measured:false marker, so the platform cannot tell an\n"+
			"absent measurement from zero sessions: %s", body)
	}
	if !strings.Contains(body, NotMeasuredVrfScopeMismatch) {
		t.Errorf("POST /status/bgp body carries no not_measured_reason: %s", body)
	}
	if !strings.Contains(body, netB) {
		t.Errorf("network %s was dropped from the report entirely; silence is not the same as a stated absence: %s",
			netB, body)
	}
}

// Zero sessions from an attributable poll is a real zero, and says so.
func TestMeasuredZeroIsMarkedMeasured(t *testing.T) {
	h := newHarness(t, networkWithBgpAndVrfJSON(netA, ifaceA, true, vrfA))
	h.mgr.FrrApplier = noopFrrApplier{}

	h.reconcile()

	body := h.lastBgpPost(t)
	if !strings.Contains(body, `"measured":true`) {
		t.Errorf("an attributable poll with no sessions was not marked measured: %s", body)
	}
}

// The observer returning a transport error is still a FAILURE, not a
// not-measured verdict — that path predates this change and must survive it.
// It is also the one arm that still drops the network out of the POST
// entirely; the heartbeat is where that absence is stated, so pin both
// halves rather than only the one that looks right.
func TestObserverErrorReportsErrorAndOmitsTheNetworkFromThePost(t *testing.T) {
	h := newHarness(t,
		networkWithBgpAndVrfJSON(netA, ifaceA, true, vrfA),
		networkWithBgpAndVrfJSON(netB, ifaceB, true, vrfB))
	h.mgr.FrrApplier = noopFrrApplier{}
	h.bgpObs.err = errors.New("vtysh: connection refused")

	h.reconcile()

	for _, nid := range []string{netA, netB} {
		if got := mustSubsystem(t, h.statusFor(t, nid), "observe_bgp", nid); got.State != SubsystemStateError {
			t.Errorf("observe_bgp/%s = %q for a failing observer, want error", nid, got.State)
		}
	}

	// Every network failed, so there is nothing to post — and post_bgp_status
	// must then be NOT MEASURED rather than a stale ok.
	h.mu.Lock()
	posts := len(h.bgpPosts)
	h.mu.Unlock()
	if posts != 0 {
		t.Errorf("POST /status/bgp made %d time(s) with no observation to report", posts)
	}
	if got, ok := findSubsystem(h.statusFor(t, netA), "post_bgp_status", ""); ok {
		t.Errorf("post_bgp_status = %q with nothing observed; want NOT MEASURED", got.State)
	}
}
