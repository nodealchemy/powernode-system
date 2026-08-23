// frr_observer.go — slice 9f: poll FRR's BGP state and report it back.
//
// `vtysh -c "show bgp [vrf <name>] summary json"` returns a structured
// snapshot of every neighbor across IPv4 + IPv6 unicast AFI/SAFI; we parse
// it into a flat list of (neighbor_address, state, uptime, rx, tx,
// last_error) tuples that the platform writes into Sdwan::BgpSession rows.
//
// Robustness:
//   * If vtysh isn't installed (e.g. static-routing-only host), the
//     observation is reported as NOT MEASURED — never as zero sessions.
//   * If the JSON shape changes between FRR major versions we degrade
//     gracefully (report not-measured) rather than panicking.
//
// Slice 9f of the SDWAN plan.
//
// ── IMP-2f34679b6b73: scope the poll, and prove the scope ─────────────
//
// FRR is ONE host-wide daemon. The platform's frr.conf is host-wide and
// multi-VRF — Sdwan::Bgp::ConfigCompiler#render_per_vrf_bgp_blocks emits one
// `router bgp <as> vrf <name>` block per VRF the host holds — so every iBGP
// network this host belongs to really does have live sessions. They just
// live in different routing contexts.
//
// This observer used to run ONE unscoped `show bgp summary` and stamp
// whatever NetworkID it was handed onto the result, so on a host with two
// iBGP networks the second network was credited with the first's neighbours.
// Reporting only the first network instead would have been the mirror-image
// lie: network two's sessions exist and would have gone unreported.
//
// So we name the VRF. What we must NOT do is ASSUME the naming took effect —
// a vtysh that ignored an unknown `vrf` argument and answered globally would
// reproduce the original bug with extra steps. FRR echoes the routing
// context it answered for as `vrfName` in each AFI block, so we CHECK it:
//
//   * vrfName present and it matches      → measured, attributable.
//   * vrfName present and it differs      → NOT MEASURED (vrf_scope_mismatch).
//     This is the arm that catches an FRR that silently fell back to global.
//   * vrfName absent (older FRR JSON)     → we cannot confirm the scope. If
//     this host has exactly ONE iBGP network there is nothing to confuse it
//     with and the answer is attributable anyway; with two or more it is NOT
//     MEASURED (vrf_scope_unconfirmed).
//
// Every arm fails CLOSED: no path returns sessions the caller cannot
// attribute, and no path returns an empty session list that reads as a
// measured zero.

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

// BgpObservationScope names the routing context one poll must answer for.
// It is the whole reason an observation can be attributed to a network:
// without it the observer has a network id and no way to tell which of the
// host's BGP instances the answer came from.
type BgpObservationScope struct {
	// NetworkID is only a LABEL for the report. It never selects anything
	// inside FRR, which is exactly why it cannot be trusted on its own.
	NetworkID string
	// VrfName is the Linux VRF this network's `router bgp` block lives in,
	// stamped by the platform from the host's Sdwan::HostVrfAssignment.
	// Empty while the assignment has not landed yet.
	VrfName string
	// SoleIbgpNetwork is true when this host has exactly one iBGP-enabled
	// network. Then — and only then — an unscoped answer is unambiguous,
	// because there is no second context it could have come from.
	SoleIbgpNetwork bool
}

// FrrObserver abstracts the vtysh poll so tests can substitute fixtures.
type FrrObserver interface {
	ObserveBgp(ctx context.Context, scope BgpObservationScope) (*ObservedBgpState, error)
}

// ShellFrrObserver shells out to `vtysh -c "show bgp [vrf <name>] summary json"`.
type ShellFrrObserver struct {
	VtyshBin string // override for tests; defaults to "vtysh"
}

func NewShellFrrObserver() *ShellFrrObserver {
	return &ShellFrrObserver{}
}

// Reasons an observation is reported as not-measured. Named constants
// because the platform stores them verbatim and an operator reads them.
const (
	NotMeasuredVrfUnassigned    = "vrf_unassigned"
	NotMeasuredVtyshUnavailable = "vtysh_unavailable"
	NotMeasuredParseFailed      = "vtysh_json_unparseable"
	NotMeasuredVrfUnknownToFrr  = "vrf_unknown_to_frr"
	NotMeasuredVrfScopeMismatch = "vrf_scope_mismatch"
	NotMeasuredScopeUnconfirmed = "vrf_scope_unconfirmed"
)

func notMeasured(scope BgpObservationScope, reason string) *ObservedBgpState {
	return &ObservedBgpState{
		NetworkID:         scope.NetworkID,
		VrfName:           scope.VrfName,
		Measured:          false,
		NotMeasuredReason: reason,
	}
}

// ObserveBgp polls FRR for ONE routing context and returns the consolidated
// session list. We fold both AFI families (ipv6Unicast + ipv4Unicast) into
// one list because the platform's BgpSession row is per-(peer, neighbor) —
// it doesn't model per-AFI separately. Stats are summed across families.
//
// Returns (state, nil) in every reachable case: an unreachable or
// unattributable FRR is a fact about the network, reported as not-measured,
// not a transport error for the caller to retry.
func (o *ShellFrrObserver) ObserveBgp(ctx context.Context, scope BgpObservationScope) (*ObservedBgpState, error) {
	// No VRF to name and more than one network that could have answered:
	// there is no query we could run whose result we could attribute.
	if scope.VrfName == "" && !scope.SoleIbgpNetwork {
		return notMeasured(scope, NotMeasuredVrfUnassigned), nil
	}

	bin := o.VtyshBin
	if bin == "" {
		bin = "vtysh"
	}

	cmd := exec.CommandContext(ctx, bin, "-c", summaryCommand(scope.VrfName))
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// vtysh missing or FRR not running. Expected on a static-mode host
		// — and still NOT a measurement of zero sessions.
		return notMeasured(scope, NotMeasuredVtyshUnavailable), nil
	}

	var raw frrSummaryRoot
	if err := json.Unmarshal(stdout.Bytes(), &raw); err != nil {
		state := notMeasured(scope, NotMeasuredParseFailed)
		state.LastError = fmt.Sprintf("parse vtysh json: %v", err)
		return state, nil
	}

	// FRR answers an unknown vrf with a warning object rather than a
	// summary. Treat any warning as "we got no answer for this context".
	if raw.Warning != nil {
		state := notMeasured(scope, NotMeasuredVrfUnknownToFrr)
		state.LastError = raw.warningMessage()
		return state, nil
	}

	// Confirm FRR answered for the context we asked about. See the header
	// comment: this is what turns "we passed a vrf argument" into evidence.
	if reason, ok := confirmScope(scope, raw.vrfName()); !ok {
		state := notMeasured(scope, reason)
		state.LastError = fmt.Sprintf("asked vrf %q, FRR answered for %q", scope.VrfName, raw.vrfName())
		return state, nil
	}

	return &ObservedBgpState{
		NetworkID: scope.NetworkID,
		VrfName:   scope.VrfName,
		RouterID:  raw.firstRouterID(),
		LocalAs:   raw.firstAs(),
		Sessions:  raw.flattenSessions(),
		Measured:  true,
	}, nil
}

// summaryCommand names the VRF when we have one. An empty VrfName only
// reaches here on a sole-iBGP host, where the global instance is the only
// thing the answer could describe.
func summaryCommand(vrfName string) string {
	if vrfName == "" {
		return "show bgp summary json"
	}
	return "show bgp vrf " + vrfName + " summary json"
}

// confirmScope decides whether an answer can be attributed to the requested
// context. Returns (notMeasuredReason, ok).
func confirmScope(scope BgpObservationScope, reported string) (string, bool) {
	if scope.VrfName == "" {
		// Sole-iBGP host, global query. Nothing to confuse it with.
		return "", true
	}
	if reported == "" {
		// An FRR build whose summary JSON carries no vrfName. On a host with
		// one iBGP network the answer is still unambiguous; with several it
		// is a guess, and a guess is what this change exists to remove.
		if scope.SoleIbgpNetwork {
			return "", true
		}
		return NotMeasuredScopeUnconfirmed, false
	}
	if reported != scope.VrfName {
		// FRR answered for a different context than we named — including the
		// case where it ignored the argument and fell back to "default".
		return NotMeasuredVrfScopeMismatch, false
	}
	return "", true
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
	// FRR replaces the whole summary with a warning object when the named
	// view/vrf does not exist. Loosely typed because the message key has
	// moved between major versions and only its PRESENCE is load-bearing.
	Warning map[string]any `json:"warning"`
}

func (r *frrSummaryRoot) warningMessage() string {
	if r.Warning == nil {
		return ""
	}
	if msg, ok := r.Warning["message"].(string); ok {
		return msg
	}
	return fmt.Sprintf("%v", r.Warning)
}

// vrfName is the routing context FRR says it answered for. Both AFI blocks
// carry it and they always agree (one instance answers one query), so the
// first one present is the answer.
func (r *frrSummaryRoot) vrfName() string {
	if r.IPv6Unicast != nil && r.IPv6Unicast.VrfName != "" {
		return r.IPv6Unicast.VrfName
	}
	if r.IPv4Unicast != nil {
		return r.IPv4Unicast.VrfName
	}
	return ""
}

type frrAfiSummary struct {
	RouterID string                     `json:"routerId"`
	As       int64                      `json:"as"`
	VrfName  string                     `json:"vrfName"`
	TableVer int                        `json:"tableVersion"`
	RibCount int                        `json:"ribCount"`
	Peers    map[string]frrAfiPeerEntry `json:"peers"`
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
