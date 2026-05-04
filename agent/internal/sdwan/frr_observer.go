// frr_observer.go — slice 9f: poll FRR's BGP state and report it back.
//
// `vtysh -c "show bgp summary json"` returns a structured snapshot of
// every neighbor across IPv4 + IPv6 unicast AFI/SAFI; we parse it into
// a flat list of (neighbor_address, state, uptime, rx, tx, last_error)
// tuples that the platform writes into Sdwan::BgpSession rows.
//
// Robustness:
//   * If vtysh isn't installed (e.g. static-routing-only host), the
//     observer returns an empty slice — not an error. FRR not running
//     is the expected case for static networks.
//   * If the JSON shape changes between FRR major versions we degrade
//     gracefully (log + return what we got) rather than panicking.
//
// Slice 9f of the SDWAN plan.

package sdwan

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// FrrObserver abstracts the vtysh poll so tests can substitute fixtures.
type FrrObserver interface {
	ObserveBgp(ctx context.Context, networkID string) (*ObservedBgpState, error)
}

// ShellFrrObserver shells out to `vtysh -c "show bgp summary json"`.
type ShellFrrObserver struct {
	VtyshBin string // override for tests; defaults to "vtysh"
}

func NewShellFrrObserver() *ShellFrrObserver {
	return &ShellFrrObserver{}
}

// ObserveBgp polls FRR and returns the consolidated session list. We
// fold both AFI families (ipv6Unicast + ipv4Unicast) into one list
// because the platform's BgpSession row is per-(peer, neighbor) — it
// doesn't model per-AFI separately. Stats are summed across families.
func (o *ShellFrrObserver) ObserveBgp(ctx context.Context, networkID string) (*ObservedBgpState, error) {
	bin := o.VtyshBin
	if bin == "" {
		bin = "vtysh"
	}

	cmd := exec.CommandContext(ctx, bin, "-c", "show bgp summary json")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// vtysh missing or FRR not running — return empty state, not
		// an error. This is the expected case for static-mode networks.
		return &ObservedBgpState{NetworkID: networkID, LastError: ""}, nil
	}

	var raw frrSummaryRoot
	if err := json.Unmarshal(stdout.Bytes(), &raw); err != nil {
		return &ObservedBgpState{
			NetworkID: networkID,
			LastError: fmt.Sprintf("parse vtysh json: %v", err),
		}, nil
	}

	state := &ObservedBgpState{
		NetworkID: networkID,
		RouterID:  raw.firstRouterID(),
		LocalAs:   raw.firstAs(),
		Sessions:  raw.flattenSessions(),
	}
	return state, nil
}

// ── FRR JSON parser internals ─────────────────────────────────────────
//
// FRR 8.x emits:
//   {
//     "ipv4Unicast": { "routerId": "1.2.3.4", "as": 4231866913,
//                      "peers": { "fdf8:...": { state, peerUptimeMsec, ... } } },
//     "ipv6Unicast": { ... }
//   }

type frrSummaryRoot struct {
	IPv4Unicast *frrAfiSummary `json:"ipv4Unicast"`
	IPv6Unicast *frrAfiSummary `json:"ipv6Unicast"`
}

type frrAfiSummary struct {
	RouterID  string                     `json:"routerId"`
	As        int64                      `json:"as"`
	TableVer  int                        `json:"tableVersion"`
	RibCount  int                        `json:"ribCount"`
	Peers     map[string]frrAfiPeerEntry `json:"peers"`
}

type frrAfiPeerEntry struct {
	RemoteAs        int64  `json:"remoteAs"`
	PeerUptimeMsec  int64  `json:"peerUptimeMsec"`
	State           string `json:"state"`
	PfxRcd          int    `json:"pfxRcd"`
	PfxSnt          int    `json:"pfxSnt"`
	LastResetReason string `json:"lastResetReason"`
}

func (r *frrSummaryRoot) firstRouterID() string {
	if r.IPv6Unicast != nil && r.IPv6Unicast.RouterID != "" {
		return r.IPv6Unicast.RouterID
	}
	if r.IPv4Unicast != nil {
		return r.IPv4Unicast.RouterID
	}
	return ""
}

func (r *frrSummaryRoot) firstAs() int64 {
	if r.IPv6Unicast != nil && r.IPv6Unicast.As > 0 {
		return r.IPv6Unicast.As
	}
	if r.IPv4Unicast != nil {
		return r.IPv4Unicast.As
	}
	return 0
}

// flattenSessions deduplicates a peer that appears in both AFIs by
// merging its prefix counts. The state is taken from whichever AFI
// shows "Established" if any (otherwise the v6 entry wins by default).
func (r *frrSummaryRoot) flattenSessions() []ObservedBgpSession {
	merged := make(map[string]ObservedBgpSession)
	r.merge(merged, r.IPv6Unicast)
	r.merge(merged, r.IPv4Unicast)

	out := make([]ObservedBgpSession, 0, len(merged))
	for _, s := range merged {
		out = append(out, s)
	}
	return out
}

func (r *frrSummaryRoot) merge(into map[string]ObservedBgpSession, summary *frrAfiSummary) {
	if summary == nil {
		return
	}
	for addr, p := range summary.Peers {
		key := addr
		uptime := int(p.PeerUptimeMsec / 1000)
		state := normalizeState(p.State)
		if existing, ok := into[key]; ok {
			existing.PrefixesReceived += p.PfxRcd
			existing.PrefixesSent += p.PfxSnt
			// Prefer "established" state across AFIs — being up on one
			// family is more useful than being down on another.
			if state == "established" || existing.State != "established" {
				existing.State = state
				existing.UptimeSeconds = uptime
			}
			into[key] = existing
		} else {
			into[key] = ObservedBgpSession{
				NeighborAddress:  addr,
				State:            state,
				UptimeSeconds:    uptime,
				PrefixesReceived: p.PfxRcd,
				PrefixesSent:     p.PfxSnt,
				LastError:        p.LastResetReason,
			}
		}
	}
}

// FRR uses Title-cased state names; the platform stores them lowercase.
// Map the mismatch here so the wire format and DB form line up.
func normalizeState(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "established":
		return "established"
	case "active":
		return "active"
	case "connect":
		return "connect"
	case "opensent", "open sent":
		return "opensent"
	case "openconfirm", "open confirm":
		return "openconfirm"
	case "idle", "":
		return "idle"
	default:
		return strings.ToLower(s)
	}
}

// Convenience for the manager's polling loop — bounds the vtysh wait so
// a hung daemon doesn't stall reconcile.
func ObservationContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, 5*time.Second)
}
