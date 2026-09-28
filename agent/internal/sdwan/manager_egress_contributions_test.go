package sdwan

import "testing"

// IMP-13645c4df90a. EgressContributions is the seam that feeds
// security.EgressExtras — these tests read Manager.lastDesired/
// lastActualListenPort directly (same package, same access Reconcile
// itself has) rather than driving a full Reconcile pass, since
// EgressContributions is a pure snapshot read with no dependency on the
// applier/transport machinery Reconcile needs.
//
// Review-round redesign: one security.EgressNetwork per desired network
// (interface name, this node's own ListenPort, and the union of its peers'
// AllowedIPs) — replaces the earlier per-peer Endpoint/FallbackEndpoint
// collection, which the review found unsafe (see egress.go's EgressNetwork
// doc).
//
// Second review round, item 5: ListenPort comes from lastActualListenPort
// (the LIVE `wg show` port Reconcile's read_actual step observed), never
// straight from the desired config's requested port — see
// lastActualListenPort's and EgressContributions' own doc for why handing
// out a port WireGuard isn't actually holding is an egress bypass, not just
// a cosmetic inaccuracy. Every fixture below sets lastActualListenPort
// explicitly alongside lastDesired to make that wiring visible.

func TestEgressContributions_NilBeforeAnyReconcile(t *testing.T) {
	m := &Manager{}
	extras := m.EgressContributions()
	if len(extras.Networks) != 0 {
		t.Fatalf("expected no contributions before any desired config is known, got %+v", extras)
	}
}

func TestEgressContributions_ReflectsLastDesired(t *testing.T) {
	m := &Manager{
		lastDesired: &DesiredConfig{
			Networks: []DesiredNetworkConfig{
				{
					NetworkID: "net-a",
					Interface: InterfaceConf{Name: "wg-sdwan-a1b2c3", ListenPort: 51820},
					Peers: []PeerConf{
						{PeerID: "hub", AllowedIPs: []string{"fd00:1::/64"}},
					},
				},
			},
		},
		lastActualListenPort: map[string]int{"wg-sdwan-a1b2c3": 51820},
	}

	extras := m.EgressContributions()
	if len(extras.Networks) != 1 {
		t.Fatalf("Networks = %+v, want exactly 1 entry", extras.Networks)
	}
	got := extras.Networks[0]
	if got.Interface != "wg-sdwan-a1b2c3" {
		t.Errorf("Interface = %q, want wg-sdwan-a1b2c3", got.Interface)
	}
	if got.ListenPort != 51820 {
		t.Errorf("ListenPort = %d, want 51820", got.ListenPort)
	}
	if len(got.AllowedIPs) != 1 || got.AllowedIPs[0] != "fd00:1::/64" {
		t.Errorf("AllowedIPs = %v, want [fd00:1::/64]", got.AllowedIPs)
	}
}

// IMP-5bfb0f482cd8: VrfName comes straight from the DESIRED interface
// config (InterfaceConf.VrfName, Phase N1a) — unlike ListenPort, there is
// no "measured/actual" VRF binding to prefer, since ReadActualState has no
// readback for it; the platform's own compiled topology is the source of
// truth for which VRF an interface belongs to.
func TestEgressContributions_CarriesVrfNameFromDesiredInterface(t *testing.T) {
	m := &Manager{
		lastDesired: &DesiredConfig{
			Networks: []DesiredNetworkConfig{
				{
					NetworkID: "net-a",
					Interface: InterfaceConf{Name: "wg-sdwan-a1b2c3", VrfName: "sdwan-100", ListenPort: 51820},
					Peers: []PeerConf{
						{PeerID: "hub", AllowedIPs: []string{"2001:db8:1::/64"}},
					},
				},
			},
		},
		lastActualListenPort: map[string]int{"wg-sdwan-a1b2c3": 51820},
	}

	extras := m.EgressContributions()
	if len(extras.Networks) != 1 {
		t.Fatalf("Networks = %+v, want exactly 1 entry", extras.Networks)
	}
	if got := extras.Networks[0].VrfName; got != "sdwan-100" {
		t.Errorf("VrfName = %q, want sdwan-100", got)
	}
}

// A network with no VRF allocated (static-only routing) must carry an
// empty VrfName, not e.g. a zero-value sentinel that renders as something
// else — egress.go's tunnelScopeRule treats "" as "no vrf clause", so this
// is the exact value that keeps that path unchanged.
func TestEgressContributions_EmptyVrfNameWhenNetworkHasNoVRF(t *testing.T) {
	m := &Manager{
		lastDesired: &DesiredConfig{
			Networks: []DesiredNetworkConfig{
				{
					NetworkID: "net-a",
					Interface: InterfaceConf{Name: "wg-sdwan-a1b2c3", ListenPort: 51820},
					Peers: []PeerConf{
						{PeerID: "hub", AllowedIPs: []string{"2001:db8:1::/64"}},
					},
				},
			},
		},
		lastActualListenPort: map[string]int{"wg-sdwan-a1b2c3": 51820},
	}

	extras := m.EgressContributions()
	if len(extras.Networks) != 1 {
		t.Fatalf("Networks = %+v, want exactly 1 entry", extras.Networks)
	}
	if got := extras.Networks[0].VrfName; got != "" {
		t.Errorf("VrfName = %q, want empty (no VRF allocated for this network)", got)
	}
}

// The bypass item 5 fixes: the DESIRED config asks for 51820, but this pass
// never measured it (or measured something else) — EgressContributions must
// hand out the OBSERVED value, never silently fall back to the request.
func TestEgressContributions_UsesLiveListenPortNotDesired(t *testing.T) {
	m := &Manager{
		lastDesired: &DesiredConfig{
			Networks: []DesiredNetworkConfig{{
				Interface: InterfaceConf{Name: "wg-sdwan-a1b2c3", ListenPort: 51820},
				Peers:     []PeerConf{{AllowedIPs: []string{"10.0.0.0/24"}}},
			}},
		},
		lastActualListenPort: map[string]int{"wg-sdwan-a1b2c3": 55555},
	}

	got := m.EgressContributions().Networks[0]
	if got.ListenPort != 55555 {
		t.Errorf("ListenPort = %d, want the LIVE port 55555, not the desired 51820", got.ListenPort)
	}
}

// The interface was never successfully read this pass (missing, down, or
// read_actual failed) — no entry in lastActualListenPort at all. Must come
// back as 0 (buildEgressExtrasRules' own "skip and log" sentinel), never
// the desired port.
func TestEgressContributions_UnmeasuredInterfaceGetsZeroNotDesiredPort(t *testing.T) {
	m := &Manager{
		lastDesired: &DesiredConfig{
			Networks: []DesiredNetworkConfig{{
				Interface: InterfaceConf{Name: "wg-sdwan-a1b2c3", ListenPort: 51820},
				Peers:     []PeerConf{{AllowedIPs: []string{"10.0.0.0/24"}}},
			}},
		},
		// lastActualListenPort deliberately nil/empty — nothing measured yet.
	}

	got := m.EgressContributions().Networks[0]
	if got.ListenPort != 0 {
		t.Errorf("ListenPort = %d, want 0 (unmeasured) since the interface was never successfully read", got.ListenPort)
	}
}

func TestEgressContributions_UnionsAllowedIPsAcrossPeers(t *testing.T) {
	m := &Manager{
		lastDesired: &DesiredConfig{
			Networks: []DesiredNetworkConfig{{
				Interface: InterfaceConf{Name: "wg-sdwan-a1b2c3", ListenPort: 51820},
				Peers: []PeerConf{
					{PeerID: "spoke-1", AllowedIPs: []string{"fd00:1::1/128"}},
					{PeerID: "spoke-2", AllowedIPs: []string{"fd00:1::2/128", "10.10.0.0/16"}},
				},
			}},
		},
		lastActualListenPort: map[string]int{"wg-sdwan-a1b2c3": 51820},
	}

	extras := m.EgressContributions()
	if len(extras.Networks) != 1 {
		t.Fatalf("Networks = %+v, want exactly 1 entry", extras.Networks)
	}
	got := extras.Networks[0].AllowedIPs
	want := map[string]bool{"fd00:1::1/128": true, "fd00:1::2/128": true, "10.10.0.0/16": true}
	if len(got) != len(want) {
		t.Fatalf("AllowedIPs = %v, want exactly %v", got, want)
	}
	for _, cidr := range got {
		if !want[cidr] {
			t.Errorf("unexpected AllowedIPs entry %q", cidr)
		}
	}
}

func TestEgressContributions_RemovedNetworkDropsOut(t *testing.T) {
	m := &Manager{
		lastDesired: &DesiredConfig{
			Networks: []DesiredNetworkConfig{
				{Interface: InterfaceConf{Name: "wg-sdwan-a1b2c3", ListenPort: 51820}, Peers: []PeerConf{{AllowedIPs: []string{"10.0.0.0/24"}}}},
				{Interface: InterfaceConf{Name: "wg-sdwan-d4e5f6", ListenPort: 51821}, Peers: []PeerConf{{AllowedIPs: []string{"10.0.1.0/24"}}}},
			},
		},
		lastActualListenPort: map[string]int{"wg-sdwan-a1b2c3": 51820, "wg-sdwan-d4e5f6": 51821},
	}
	before := m.EgressContributions()
	if len(before.Networks) != 2 {
		t.Fatalf("setup: expected 2 networks before the removal, got %v", before.Networks)
	}

	// Simulate the next Reconcile tick's desired config — network 2 is gone,
	// exactly as m.lastDesired/lastActualListenPort are replaced wholesale
	// at the end of Reconcile.
	m.lastDesired = &DesiredConfig{
		Networks: []DesiredNetworkConfig{
			{Interface: InterfaceConf{Name: "wg-sdwan-a1b2c3", ListenPort: 51820}, Peers: []PeerConf{{AllowedIPs: []string{"10.0.0.0/24"}}}},
		},
	}
	m.lastActualListenPort = map[string]int{"wg-sdwan-a1b2c3": 51820}

	after := m.EgressContributions()
	if len(after.Networks) != 1 || after.Networks[0].Interface != "wg-sdwan-a1b2c3" {
		t.Errorf("Networks = %+v, want only wg-sdwan-a1b2c3 after the removal", after.Networks)
	}
}
