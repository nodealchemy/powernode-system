// route_applier.go — IMP-470b28a77962: installs and reaps kernel routes
// for a WireGuard interface's peer AllowedIPs.
//
// The wg handshake alone never gets traffic flowing: WireGuard's own
// crypto-routing (AllowedIPs) decides which OUTBOUND packets get
// encrypted onto a given peer, but does nothing to make the kernel's
// own routing table send traffic TOWARD that peer's AllowedIPs via this
// interface in the first place — that's an ordinary route, and nothing
// in this package installed one before this file existed. Symptom: a
// completed handshake with "Network is unreachable" for any address in
// the overlay beyond the peer's own /128.
//
// Called by the manager as its own reconcile step (Manager.ApplyRoutes
// — see wg_applier.go's WgApplier interface doc for why this is
// deliberately NOT folded into ApplyInterface), unconditionally on
// every tick, right after apply_interface succeeds. Unlike the
// link/master/MTU steps in ApplyInterface, this is NOT gated behind
// readLinkState's drift check: review round B2/nit — cycling the
// DEVICE (an `ip link set master` bind, or an MTU/up bounce) flushes
// that device's own routes, so "the link state already matched" says
// nothing about whether the routes survived.

package sdwan

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

const (
	// sdwanRouteProto marks every route this package installs, so
	// reaping can identify "ours" without any dst/dev heuristic —
	// review round SF1. Chosen from iproute2's unassigned range: not in
	// the default Debian/Ubuntu /etc/iproute2/rt_protos (kernel: 1
	// redirect, 2 kernel, 3 boot, 4 static, 8 gated, 9 ra, 10 mrt, 11
	// zebra, 12 bird, 13 dnrouted, 14 xorp, 15 ntk, 16 dhcp, 17
	// mrouted, 18 keepalived, 42 babel) and not one of the common
	// FRR/BIRD daemon ids (186-196: bgp/isis/ospf/rip/eigrp/ospf6/...).
	// iproute2 prints the bare number for any id it has no name for, so
	// the reap-side comparison is against the literal string "241".
	sdwanRouteProto = 241
	// sdwanRouteMetric is both the install metric and part of the
	// reap-side ownership check (SF1/SF4): a route sharing proto+dev
	// but installed at a different metric was NOT put there by this
	// package's own replaceRoute, and is left alone.
	sdwanRouteMetric = 1024
)

var (
	sdwanRouteProtoStr  = strconv.Itoa(sdwanRouteProto)
	sdwanRouteMetricStr = strconv.Itoa(sdwanRouteMetric)
)

// canonicalRouteDst validates and canonicalizes one AllowedIPs entry
// into the destination iproute2 expects for a route.
//
//   - Must parse as a valid address+prefix-length (net/netip.ParsePrefix).
//   - Host bits are MASKED, not rejected (review round SF2 — reverses
//     this function's original behavior). WireGuard's own cryptokey
//     routing masks AllowedIPs the same way before deciding what to
//     encrypt (see wireguard(8) / the kernel's allowedips trie), so the
//     route installed here has to match what's ACTUALLY reachable
//     through the tunnel regardless of what the platform sent — a
//     reject here would silently drop overlay reachability for a peer
//     over what WireGuard itself treats as a cosmetic input difference.
//   - Rejects an IPv4-mapped IPv6 address (::ffff:a.b.c.d/n) — netip
//     parses it without complaint, but it has no meaningful separate
//     VRF-route semantics from the plain IPv4 form here, and letting it
//     through would let one destination be desired under two different
//     string encodings. Still an outright reject (unlike host bits):
//     there's no WireGuard-side precedent coercing this one.
func canonicalRouteDst(cidr string) (netip.Prefix, error) {
	p, err := netip.ParsePrefix(strings.TrimSpace(cidr))
	if err != nil {
		return netip.Prefix{}, fmt.Errorf("invalid route CIDR %q: %w", cidr, err)
	}
	if p.Addr().Is4In6() {
		return netip.Prefix{}, fmt.Errorf("invalid route CIDR %q: IPv4-mapped IPv6 address not accepted", cidr)
	}
	return p.Masked(), nil
}

// reconcilePeerRoutes installs a route for every peer's AllowedIPs entry
// and reaps any sdwanRouteProto route on this device that's no longer
// desired. A malformed AllowedIPs entry (parse failure or an IPv4-mapped
// IPv6 address — see canonicalRouteDst), or a failure installing/
// reaping one specific route, is collected and returned but never stops
// processing the rest. Desired/stale entries are processed in sorted
// order so command sequence — and this function's error text — is
// deterministic across runs (nit). Nothing passed through here can ever
// be key material (AllowedIPs carries none), so no redaction is needed
// on the returned error.
//
// Review round B3 (BLOCKER): with no VRF, `ip route replace` operates on
// the MAIN table, which the underlay itself uses. `ip route replace`
// matches on dst[+tos for IPv4]+metric — NOT on dev — so a peer
// AllowedIPs entry that happens to collide with the node's own DHCP
// default route or connected LAN route at the SAME metric this package
// uses would silently overwrite it: e.g. a peer's lan_subnet equal to
// the underlay LAN, or a pushed 0.0.0.0/0. That can brick the node
// remotely with no local recovery path. A VRF isolates its own table
// from the underlay entirely, so this risk is specific to the no-VRF
// (static-only routing, no VRF allocated) case. Decided: install and
// reap NOTHING when there's no VRF, rather than attempt any
// main-table-safe workaround. There's no separate info-level log sink
// in this package (recordError/recordSuccess only carry pass/fail, not
// an informational message) — flagged to the reviewer rather than
// inventing one for this task; the apply_routes step still records a
// plain success for this tick, and this comment is the "note".
func reconcilePeerRoutes(ctx context.Context, ip, ifname, vrfName string, peers []PeerConf) error {
	if vrfName == "" {
		return nil
	}

	desired := make(map[string]netip.Prefix)
	var errs []error

	for _, p := range peers {
		for _, raw := range p.AllowedIPs {
			prefix, err := canonicalRouteDst(raw)
			if err != nil {
				errs = append(errs, fmt.Errorf("peer %s: %w", p.PublicKey, err))
				continue
			}
			desired[prefix.String()] = prefix
		}
	}

	desiredKeys := make([]string, 0, len(desired))
	for k := range desired {
		desiredKeys = append(desiredKeys, k)
	}
	sort.Strings(desiredKeys)

	// `ip route replace` is idempotent — reissuing an already-correct
	// route, or one already covered by the interface's own connected
	// route, is a harmless no-op. Same reasoning as calling `wg
	// syncconf` unconditionally every tick.
	for _, key := range desiredKeys {
		if err := replaceRoute(ctx, ip, ifname, vrfName, desired[key]); err != nil {
			errs = append(errs, err)
		}
	}

	if err := reapStaleRoutes(ctx, ip, ifname, vrfName, desired); err != nil {
		errs = append(errs, err)
	}

	return errors.Join(errs...)
}

// replaceRoute installs/refreshes one destination route for ifname,
// scoped to vrfName's table (never empty — reconcilePeerRoutes' B3
// guard means this is only ever called with a real VRF).
func replaceRoute(ctx context.Context, ip, ifname, vrfName string, prefix netip.Prefix) error {
	family := "-4"
	if prefix.Addr().Is6() {
		family = "-6"
	}
	args := []string{family, "route", "replace", prefix.String(), "dev", ifname, "vrf", vrfName,
		"proto", sdwanRouteProtoStr, "metric", sdwanRouteMetricStr}
	if err := run(ctx, ip, args...); err != nil {
		return fmt.Errorf("ip route replace %s dev %s: %w", prefix, ifname, err)
	}
	return nil
}

// reapStaleRoutes deletes every sdwanRouteProto route on ifname that is
// not in desired — e.g. a peer removed from the network, or an
// AllowedIPs entry the platform stopped sending. Best-effort per route:
// one deletion failing doesn't stop the others. Processed in sorted
// order for deterministic command sequence (nit).
func reapStaleRoutes(ctx context.Context, ip, ifname, vrfName string, desired map[string]netip.Prefix) error {
	actual, err := listSdwanRoutesOnDevice(ctx, ip, ifname, vrfName)
	if err != nil {
		return fmt.Errorf("list sdwan routes on %s: %w", ifname, err)
	}

	staleKeys := make([]string, 0, len(actual))
	for key := range actual {
		if _, ok := desired[key]; ok {
			continue
		}
		staleKeys = append(staleKeys, key)
	}
	sort.Strings(staleKeys)

	var errs []error
	for _, key := range staleKeys {
		if err := delRoute(ctx, ip, ifname, vrfName, actual[key]); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// delRoute removes one destination route for ifname. Always includes
// `proto <sdwanRouteProto> metric <sdwanRouteMetric>` in the delete
// itself — belt-and-suspenders alongside listSdwanRoutesOnDevice's own
// filtering, so a delete command built from this package's own listing
// can never be handed a route this package didn't itself install, even
// if some future caller change stopped pre-filtering.
func delRoute(ctx context.Context, ip, ifname, vrfName string, prefix netip.Prefix) error {
	family := "-4"
	if prefix.Addr().Is6() {
		family = "-6"
	}
	args := []string{family, "route", "del", prefix.String(), "dev", ifname, "vrf", vrfName,
		"proto", sdwanRouteProtoStr, "metric", sdwanRouteMetricStr}
	if err := run(ctx, ip, args...); err != nil {
		return fmt.Errorf("ip route del %s dev %s: %w", prefix, ifname, err)
	}
	return nil
}

// routeShowEntry mirrors the fields this package reads from `ip -j
// route show ...` JSON. Unrecognized fields (there are many more in
// real iproute2 output — src, flags, pref, ...) are ignored by
// json.Unmarshal, not an error.
type routeShowEntry struct {
	Dst      string `json:"dst"`
	Dev      string `json:"dev"`
	Protocol string `json:"protocol"`
	Metric   int    `json:"metric"`
}

// listSdwanRoutesOnDevice returns the canonical destinations of every
// route this package owns (proto sdwanRouteProto, dev ifname, metric
// sdwanRouteMetric) currently installed in vrfName's table, across both
// address families.
//
// Review round B1 (BLOCKER): this used to list with `dev <ifname> proto
// static` IN THE COMMAND ITSELF, on the assumption that filtering would
// leave those fields out of scope for the parser to even worry about.
// Verified against real iproute2 6.1 output: when a field is used as a
// show FILTER, iproute2 OMITS that field from each entry's JSON — it's
// redundant with what the caller already asked for. So a listing
// filtered on `dev`+`proto` never printed "dev" or "protocol" at all,
// which made the old `e.Protocol != "static"` check true for every
// entry (Protocol was always the zero value ""), so reaping could never
// delete anything actually stale. Fixed by listing WITHOUT the dev/proto
// filter (only `vrf <vrf>`, which is a table selector, not a
// per-route field, so it stays) and doing dev/proto/metric matching
// here in Go against a full, unfiltered listing where those fields are
// always present.
//
// All three conditions matter for reap-safety: dev, so a route on a
// different SDWAN interface sharing this VRF is never touched by the
// wrong caller; proto, so an operator's or systemd-networkd's own
// static route is left alone; metric, so a route sharing proto+dev but
// NOT installed at sdwanRouteMetric — i.e., something this package
// didn't itself put there — survives too (SF1/SF4).
func listSdwanRoutesOnDevice(ctx context.Context, ip, ifname, vrfName string) (map[string]netip.Prefix, error) {
	result := make(map[string]netip.Prefix)

	for _, family := range []string{"-4", "-6"} {
		args := []string{family, "-j", "route", "show", "vrf", vrfName}
		cmd := exec.CommandContext(ctx, ip, args...)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			// No routes of this family in this table — some
			// iproute2/kernel combinations exit nonzero with empty
			// output for "nothing matched" rather than an empty JSON
			// array. Treat as zero routes, same convention as
			// captureLinkShow elsewhere in this package. Any OTHER
			// failure (nonempty output alongside the nonzero exit)
			// aborts the WHOLE listing — for both families, since we
			// return here rather than merely `continue` — so a caller
			// with incomplete information never proceeds to delete
			// anything based on a partial view (SF4).
			if stdout.Len() == 0 {
				continue
			}
			return nil, fmt.Errorf("ip %s route show vrf %s: %w; stderr=%s", family, vrfName, err, stderr.String())
		}

		var entries []routeShowEntry
		if err := json.Unmarshal(stdout.Bytes(), &entries); err != nil {
			return nil, fmt.Errorf("parse route-show json (%s): %w", family, err)
		}
		for _, e := range entries {
			if e.Dev != ifname || e.Protocol != sdwanRouteProtoStr || e.Metric != sdwanRouteMetric {
				continue
			}
			prefix, ok := parseRouteShowDst(e.Dst, family)
			if !ok {
				// Something iproute2 emitted that this package's own
				// canonicalizer wouldn't have produced itself — skip
				// rather than risk deleting or mis-keying it.
				continue
			}
			result[prefix.String()] = prefix
		}
	}
	return result, nil
}

// parseRouteShowDst interprets one entry's "dst" field from `ip -j
// route show` output for the given family ("-4" or "-6"), handling the
// two renderings that never look like a plain CIDR:
//   - a host route prints as a bare address with no "/n" suffix at all
//     (e.g. a peer's own /128, this package's most common case);
//   - the default route prints as the literal string "default" rather
//     than "0.0.0.0/0" or "::/0" (review round SF3) — mapped to the
//     family's zero prefix so a stale default route this package once
//     installed can be reaped like any other entry, instead of being
//     silently invisible to listSdwanRoutesOnDevice's parser.
func parseRouteShowDst(dst, family string) (netip.Prefix, bool) {
	if dst == "" {
		return netip.Prefix{}, false
	}
	if dst == "default" {
		if family == "-6" {
			return netip.MustParsePrefix("::/0"), true
		}
		return netip.MustParsePrefix("0.0.0.0/0"), true
	}
	if !strings.Contains(dst, "/") {
		if strings.Contains(dst, ":") {
			dst += "/128"
		} else {
			dst += "/32"
		}
	}
	p, err := netip.ParsePrefix(dst)
	if err != nil {
		return netip.Prefix{}, false
	}
	return p, true
}
