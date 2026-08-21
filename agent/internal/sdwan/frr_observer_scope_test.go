package sdwan

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// IMP-2f34679b6b73 — the observer runs ONE global `vtysh show bgp summary`
// and stamps whatever NetworkID it was handed onto the result. On a host
// carrying two iBGP networks that means network B's peers are credited with
// network A's live sessions: a measurement that was never taken for B.
//
// The platform's frr.conf is host-wide and multi-VRF (Sdwan::Bgp::ConfigCompiler
// #render_per_vrf_bgp_blocks emits one `router bgp <as> vrf <name>` per host
// VRF), so both networks DO have live sessions — they just live in different
// VRFs. The query has to name the VRF or the answer cannot be attributed.

// Neighbors of network A live in the default (global) BGP instance in this
// fixture; network B's live in vrf pnv-bbbb.
const globalOnlySummaryJSON = `{
  "ipv6Unicast": {
    "routerId": "10.0.0.1",
    "as": 4231866913,
    "vrfId": 0,
    "vrfName": "default",
    "peers": {
      "fd00:aaaa::2": {"remoteAs": 4231866913, "state": "Established", "peerUptimeMsec": 3600000, "pfxRcd": 5, "pfxSnt": 3}
    }
  }
}`

const vrfBSummaryJSON = `{
  "ipv6Unicast": {
    "routerId": "10.0.0.2",
    "as": 4231866913,
    "vrfId": 7,
    "vrfName": "pnv-bbbb",
    "peers": {
      "fd00:bbbb::2": {"remoteAs": 4231866913, "state": "Established", "peerUptimeMsec": 60000, "pfxRcd": 1, "pfxSnt": 1}
    }
  }
}`

// writeFakeVtysh installs an executable stub that dispatches on the `-c`
// command string and appends every invocation to a log file. Returns the
// binary path and the log path.
func writeFakeVtysh(t *testing.T, body string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "vtysh")
	log := filepath.Join(dir, "invocations.log")
	script := "#!/bin/sh\necho \"$*\" >> " + log + "\n" + body
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake vtysh: %v", err)
	}
	return bin, log
}

func readInvocations(t *testing.T, log string) []string {
	t.Helper()
	raw, err := os.ReadFile(log)
	if err != nil {
		return nil
	}
	out := []string{}
	for _, l := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(l) != "" {
			out = append(out, l)
		}
	}
	return out
}

// A vtysh that only ever knows about the global instance — exactly what a
// host looks like from the observer's side today, since the observer never
// names a VRF.
const alwaysGlobalBody = `cat <<'JSON'
` + globalOnlySummaryJSON + `
JSON
`

// A vtysh that DOES honour the vrf argument — the FRR the platform targets.
const vrfAwareBody = `case "$*" in
  *"vrf pnv-bbbb"*)
cat <<'JSON'
` + vrfBSummaryJSON + `
JSON
  ;;
  *)
cat <<'JSON'
` + globalOnlySummaryJSON + `
JSON
  ;;
esac
`

func scopeB(sole bool) BgpObservationScope {
	return BgpObservationScope{NetworkID: "net-bbbb2222", VrfName: "pnv-bbbb", SoleIbgpNetwork: sole}
}

// The original defect: an unscoped poll answers for one routing context and
// the caller stamps a second network's id onto it.
func TestObserverDoesNotAttributeGlobalSessionsToASecondNetwork(t *testing.T) {
	// The adversarial case — a vtysh that IGNORES the vrf argument and
	// answers globally anyway. If the fix only passed the argument and
	// trusted it, this would reproduce the bug with extra steps.
	bin, log := writeFakeVtysh(t, alwaysGlobalBody)
	obs := &ShellFrrObserver{VtyshBin: bin}

	state, err := obs.ObserveBgp(context.Background(), scopeB(false))
	if err != nil {
		t.Fatalf("ObserveBgp: %v", err)
	}

	for _, s := range state.Sessions {
		if s.NeighborAddress == "fd00:aaaa::2" {
			t.Errorf("network net-bbbb2222 was credited with neighbor %s, which belongs to another network's BGP instance; "+
				"invocations=%v", s.NeighborAddress, readInvocations(t, log))
		}
	}
	if state.Measured {
		t.Errorf("Measured = true although FRR answered for %q, not the VRF we asked about", "default")
	}
	if state.NotMeasuredReason != NotMeasuredVrfScopeMismatch {
		t.Errorf("NotMeasuredReason = %q, want %q", state.NotMeasuredReason, NotMeasuredVrfScopeMismatch)
	}
}

// The poll must name the VRF; without it nothing in the query distinguishes
// one of the host's networks from another.
func TestObserverScopesTheQueryToTheNetworksVrf(t *testing.T) {
	bin, log := writeFakeVtysh(t, vrfAwareBody)
	obs := &ShellFrrObserver{VtyshBin: bin}

	state, err := obs.ObserveBgp(context.Background(), scopeB(false))
	if err != nil {
		t.Fatalf("ObserveBgp: %v", err)
	}

	inv := readInvocations(t, log)
	if len(inv) == 0 {
		t.Fatalf("fake vtysh was never invoked")
	}
	for _, i := range inv {
		if !strings.Contains(i, "vrf pnv-bbbb") {
			t.Errorf("vtysh invoked as %q — no VRF named, so the answer cannot be attributed to one network", i)
		}
	}

	if !state.Measured {
		t.Fatalf("Measured = false for a VRF FRR confirmed answering for: reason %q", state.NotMeasuredReason)
	}
	if len(state.Sessions) != 1 || state.Sessions[0].NeighborAddress != "fd00:bbbb::2" {
		t.Errorf("sessions = %+v, want only network B's own neighbour", state.Sessions)
	}
}

// vtysh missing / FRR down must not read downstream as "measured, zero
// sessions" — that is a healthy-looking network nobody looked at.
func TestObserverDistinguishesUnavailableFrrFromZeroSessions(t *testing.T) {
	obs := &ShellFrrObserver{VtyshBin: filepath.Join(t.TempDir(), "does-not-exist")}

	state, err := obs.ObserveBgp(context.Background(), BgpObservationScope{
		NetworkID: "net-aaaa1111", SoleIbgpNetwork: true,
	})
	if err != nil {
		t.Fatalf("ObserveBgp: %v", err)
	}
	if state.Measured {
		t.Errorf("state.Measured = true with vtysh absent; nothing was measured")
	}
	if state.NotMeasuredReason != NotMeasuredVtyshUnavailable {
		t.Errorf("NotMeasuredReason = %q, want %q", state.NotMeasuredReason, NotMeasuredVtyshUnavailable)
	}
}

// An FRR whose summary JSON carries no vrfName leaves the scope unconfirmed.
// With one iBGP network on the host that is still attributable; with two it
// is a guess, and the whole point of this change is to stop guessing.
func TestObserverHandlesFrrThatOmitsVrfName(t *testing.T) {
	const noVrfNameJSON = `{"ipv6Unicast":{"routerId":"10.0.0.2","as":4231866913,` +
		`"peers":{"fd00:bbbb::2":{"remoteAs":4231866913,"state":"Established","peerUptimeMsec":60000}}}}`
	body := "cat <<'JSON'\n" + noVrfNameJSON + "\nJSON\n"

	t.Run("sole iBGP network: attributable anyway", func(t *testing.T) {
		bin, _ := writeFakeVtysh(t, body)
		obs := &ShellFrrObserver{VtyshBin: bin}
		state, _ := obs.ObserveBgp(context.Background(), scopeB(true))
		if !state.Measured {
			t.Errorf("Measured = false on a sole-iBGP host: reason %q — the fix went dark instead of scoping",
				state.NotMeasuredReason)
		}
		if len(state.Sessions) != 1 {
			t.Errorf("sessions = %+v, want the one neighbour FRR reported", state.Sessions)
		}
	})

	t.Run("two iBGP networks: not measured", func(t *testing.T) {
		bin, _ := writeFakeVtysh(t, body)
		obs := &ShellFrrObserver{VtyshBin: bin}
		state, _ := obs.ObserveBgp(context.Background(), scopeB(false))
		if state.Measured {
			t.Errorf("Measured = true although nothing confirmed which context answered")
		}
		if state.NotMeasuredReason != NotMeasuredScopeUnconfirmed {
			t.Errorf("NotMeasuredReason = %q, want %q", state.NotMeasuredReason, NotMeasuredScopeUnconfirmed)
		}
		if len(state.Sessions) != 0 {
			t.Errorf("sessions = %+v on an unattributable poll; want none", state.Sessions)
		}
	})
}

// The sole-iBGP host whose HostVrfAssignment has not landed yet: VrfName is
// empty, so the poll is global. That is allowed ONLY because there is one
// network it could describe — and it must stay allowed, or a fleet whose VRF
// rollout is mid-flight goes dark instead of being scoped.
func TestObserverMeasuresSoleIbgpHostWithNoVrfAssignedYet(t *testing.T) {
	bin, log := writeFakeVtysh(t, alwaysGlobalBody)
	obs := &ShellFrrObserver{VtyshBin: bin}

	state, err := obs.ObserveBgp(context.Background(), BgpObservationScope{
		NetworkID: "net-aaaa1111", VrfName: "", SoleIbgpNetwork: true,
	})
	if err != nil {
		t.Fatalf("ObserveBgp: %v", err)
	}
	if !state.Measured {
		t.Fatalf("Measured = false (reason %q) on a sole-iBGP host with no VRF yet; "+
			"the poll is unambiguous and going dark is not the conservative choice", state.NotMeasuredReason)
	}
	if len(state.Sessions) != 1 || state.Sessions[0].NeighborAddress != "fd00:aaaa::2" {
		t.Errorf("sessions = %+v, want the global instance's one neighbour", state.Sessions)
	}
	inv := readInvocations(t, log)
	if len(inv) != 1 || strings.Contains(inv[0], "vrf ") {
		t.Errorf("vtysh invoked as %v, want one unscoped global summary", inv)
	}
}

// FRR answers an unknown vrf with a warning object instead of a summary.
func TestObserverTreatsFrrVrfWarningAsNotMeasured(t *testing.T) {
	body := "cat <<'JSON'\n" + `{"warning":{"message":"View/Vrf is unknown"}}` + "\nJSON\n"
	bin, _ := writeFakeVtysh(t, body)
	obs := &ShellFrrObserver{VtyshBin: bin}

	state, _ := obs.ObserveBgp(context.Background(), scopeB(false))
	if state.Measured {
		t.Errorf("Measured = true for a vrf FRR says it does not know")
	}
	if state.NotMeasuredReason != NotMeasuredVrfUnknownToFrr {
		t.Errorf("NotMeasuredReason = %q, want %q", state.NotMeasuredReason, NotMeasuredVrfUnknownToFrr)
	}
	if !strings.Contains(state.LastError, "View/Vrf is unknown") {
		t.Errorf("LastError = %q, want FRR's own message", state.LastError)
	}
}

// A host with several iBGP networks and no VRF assignment yet has no query
// whose answer could be attributed. It must not fall back to the global one.
func TestObserverRefusesUnscopedPollWhenHostHasSeveralIbgpNetworks(t *testing.T) {
	bin, log := writeFakeVtysh(t, alwaysGlobalBody)
	obs := &ShellFrrObserver{VtyshBin: bin}

	state, _ := obs.ObserveBgp(context.Background(), BgpObservationScope{
		NetworkID: "net-bbbb2222", VrfName: "", SoleIbgpNetwork: false,
	})
	if state.Measured {
		t.Errorf("Measured = true from an unscoped poll on a multi-iBGP host")
	}
	if state.NotMeasuredReason != NotMeasuredVrfUnassigned {
		t.Errorf("NotMeasuredReason = %q, want %q", state.NotMeasuredReason, NotMeasuredVrfUnassigned)
	}
	if inv := readInvocations(t, log); len(inv) != 0 {
		t.Errorf("vtysh was invoked %v; a poll whose answer cannot be attributed should not run at all", inv)
	}
}

// An IPv4-only FRR summary — the shape a host with no IPv6 unicast AFI
// returns. The scope confirmation has to read vrfName out of THAT block too,
// or every such host reports vrf_scope_unconfirmed forever.
func TestObserverConfirmsScopeFromTheIPv4BlockWhenThereIsNoIPv6(t *testing.T) {
	const ipv4OnlyJSON = `{"ipv4Unicast":{"routerId":"10.0.0.2","as":4231866913,` +
		`"vrfName":"pnv-bbbb","peers":{"10.9.0.2":{"remoteAs":4231866913,"state":"Established","pfxRcd":2}}}}`
	bin, _ := writeFakeVtysh(t, "cat <<'JSON'\n"+ipv4OnlyJSON+"\nJSON\n")
	obs := &ShellFrrObserver{VtyshBin: bin}

	state, err := obs.ObserveBgp(context.Background(), scopeB(false))
	if err != nil {
		t.Fatalf("ObserveBgp: %v", err)
	}
	if !state.Measured {
		t.Fatalf("Measured = false (reason %q) although ipv4Unicast confirmed vrfName pnv-bbbb",
			state.NotMeasuredReason)
	}
	if len(state.Sessions) != 1 || state.Sessions[0].NeighborAddress != "10.9.0.2" {
		t.Errorf("sessions = %+v, want the one v4 neighbour", state.Sessions)
	}
}

// FRR 8.x can emit an ipv6Unicast block without a vrfName while ipv4Unicast
// carries one. vrfName() has to fall through to the v4 block rather than
// stopping at a present-but-empty v6 field, or the scope reads unconfirmed.
func TestObserverFallsThroughAnEmptyIPv6VrfNameToTheIPv4Block(t *testing.T) {
	const mixedJSON = `{"ipv6Unicast":{"routerId":"10.0.0.2","as":4231866913,` +
		`"peers":{"fd00:bbbb::2":{"remoteAs":4231866913,"state":"Established"}}},` +
		`"ipv4Unicast":{"routerId":"10.0.0.2","as":4231866913,"vrfName":"pnv-bbbb","peers":{}}}`
	bin, _ := writeFakeVtysh(t, "cat <<'JSON'\n"+mixedJSON+"\nJSON\n")
	obs := &ShellFrrObserver{VtyshBin: bin}

	state, err := obs.ObserveBgp(context.Background(), scopeB(false))
	if err != nil {
		t.Fatalf("ObserveBgp: %v", err)
	}
	if !state.Measured {
		t.Fatalf("Measured = false (reason %q) although ipv4Unicast confirmed the vrf", state.NotMeasuredReason)
	}
	if len(state.Sessions) != 1 || state.Sessions[0].NeighborAddress != "fd00:bbbb::2" {
		t.Errorf("sessions = %+v, want the v6 neighbour", state.Sessions)
	}
}

// A malformed payload is an absence of a measurement, not zero sessions.
func TestObserverTreatsUnparseableJsonAsNotMeasured(t *testing.T) {
	bin, _ := writeFakeVtysh(t, "echo 'not json at all'\n")
	obs := &ShellFrrObserver{VtyshBin: bin}

	state, _ := obs.ObserveBgp(context.Background(), scopeB(false))
	if state.Measured {
		t.Errorf("Measured = true for an unparseable vtysh payload")
	}
	if state.NotMeasuredReason != NotMeasuredParseFailed {
		t.Errorf("NotMeasuredReason = %q, want %q", state.NotMeasuredReason, NotMeasuredParseFailed)
	}
}
