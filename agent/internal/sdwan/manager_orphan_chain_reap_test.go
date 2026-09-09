// manager_orphan_chain_reap_test.go — the orphan nft chain reap.
//
// IMP-01a07d31. The reaper derived the chain name from the orphaned
// WireGuard interface's suffix:
//
//	netShort := name[len("wg-sdwan-"):]        // "7"
//	RemoveChain(..., Chain: "sdwan_"+netShort) // "sdwan_7" — no such chain
//
// Those two suffixes are different strings and always were. The chain is
// `sdwan_<network_handle>` (Sdwan::FirewallCompiler#net_short_id) while the
// interface is `wg-sdwan-<short_id>`, a small per-host integer allocated by
// Sdwan::HostVrfAssignment. FirewallCompiler's header says so in as many
// words — "The chain suffix and the interface suffix are NOT the same string;
// do not derive one from the other (IMP-54fdf40fbf9d)" — which is the same
// defect, fixed on the server side and left standing here.
//
// So every reap named a chain that has never existed on any host holding a
// VRF assignment, and nft answered "Object does not exist", which this path
// swallows by design. It coincidentally hit only in the fallback case: a
// static-only network with no assignment, where the interface carries the
// handle too.
//
// The fix stops deriving anything. Chains are reaped the way interfaces one
// loop above already are — ACTUAL (listed from the kernel) minus DESIRED (the
// chain names the platform sent) — which needs no name mapping at all and
// survives an agent restart, when no in-memory pairing would.
package sdwan

import (
	"strings"
	"testing"
)

// The two suffixes a host with a VRF assignment actually carries. Kept as
// named constants because the whole point is that they DIFFER: a future
// edit that makes them equal would make every example below pass vacuously.
const (
	reapNetHandle = "019deffa"   // chain suffix — Sdwan::Network#network_handle
	reapIfaceName = "wg-sdwan-7" // iface — HostVrfAssignment#wg_iface_name
	reapOrphanIf  = "wg-sdwan-9" // an interface we have no desired config for
	reapOrphanNet = "0000dead"   // the departed network's handle
)

func TestReapsOrphanChainsByListedName(t *testing.T) {
	h := newHarness(t, networkJSON(reapNetHandle, reapIfaceName, true, true))
	h.wg.existing = []string{reapIfaceName, reapOrphanIf}
	h.nft.chains = []string{
		"sdwan_" + reapNetHandle, "sdwan_nat_" + reapNetHandle,
		"sdwan_" + reapOrphanNet, "sdwan_nat_" + reapOrphanNet,
	}

	h.reconcile()

	if !contains(h.nft.removedChains, "sdwan_"+reapOrphanNet) {
		t.Fatalf("orphan filter chain was not reaped; removals=%v", h.nft.removedChains)
	}
	if !contains(h.nat.removedChains, "sdwan_nat_"+reapOrphanNet) {
		t.Fatalf("orphan nat chain was not reaped; removals=%v", h.nat.removedChains)
	}
}

// The failure this replaces was silent because nft swallows "no such chain".
// Asserting on the ABSENCE of the derived name is what separates "reaps the
// right chain" from "reaps nothing and always did".
func TestNeverReapsAChainDerivedFromTheInterfaceSuffix(t *testing.T) {
	h := newHarness(t, networkJSON(reapNetHandle, reapIfaceName, true, true))
	h.wg.existing = []string{reapIfaceName, reapOrphanIf}
	h.nft.chains = []string{"sdwan_" + reapNetHandle, "sdwan_" + reapOrphanNet}

	h.reconcile()

	for _, name := range append(h.nft.removedChains, h.nat.removedChains...) {
		if strings.HasSuffix(name, "_9") {
			t.Fatalf("reap derived a chain name from the interface suffix: %q", name)
		}
	}
}

func TestLeavesADesiredNetworksChainsAlone(t *testing.T) {
	h := newHarness(t, networkJSON(reapNetHandle, reapIfaceName, true, true))
	h.wg.existing = []string{reapIfaceName}
	h.nft.chains = []string{"sdwan_" + reapNetHandle, "sdwan_nat_" + reapNetHandle}

	h.reconcile()

	if len(h.nft.removedChains) != 0 || len(h.nat.removedChains) != 0 {
		t.Fatalf("reaped a live network's chains: filter=%v nat=%v",
			h.nft.removedChains, h.nat.removedChains)
	}
}

// A chain the compilers do not own must survive: the table is shared, and a
// reaper that deletes anything it cannot attribute is worse than one that
// deletes nothing.
func TestLeavesForeignChainsInTheTableAlone(t *testing.T) {
	h := newHarness(t, networkJSON(reapNetHandle, reapIfaceName, true, true))
	h.wg.existing = []string{reapIfaceName}
	h.nft.chains = []string{"sdwan_" + reapNetHandle, "some_other_chain", "input"}

	h.reconcile()

	if len(h.nft.removedChains) != 0 {
		t.Fatalf("reaped a chain the SDWAN compilers do not own: %v", h.nft.removedChains)
	}
}

// Fail-safe. TopologyCompiler emits firewall AND nat for every network, so a
// desired network with the block missing means the payload is incomplete —
// an older platform, a partial response. The desired set is then unknowable,
// and reaping against an incomplete set would delete live policy. Skip
// instead: a chain left standing is recoverable, a deleted one is an outage.
func TestSkipsTheReapWhenADesiredNetworkSentNoFirewallBlock(t *testing.T) {
	h := newHarness(t,
		networkJSON(reapNetHandle, reapIfaceName, true, true),
		networkJSON("019dbeef", "wg-sdwan-8", false, true),
	)
	h.wg.existing = []string{reapIfaceName, "wg-sdwan-8", reapOrphanIf}
	h.nft.chains = []string{"sdwan_" + reapNetHandle, "sdwan_" + reapOrphanNet}

	h.reconcile()

	if len(h.nft.removedChains) != 0 {
		t.Fatalf("reaped against an incomplete desired set: %v", h.nft.removedChains)
	}
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
