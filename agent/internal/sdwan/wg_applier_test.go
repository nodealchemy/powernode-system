// wg_applier_test.go — Phase N1a regression: ApplyInterface must bind
// the freshly-created WG iface to its network's VRF master device.
//
// Pre-N1a, ApplyInterface created the iface with no VRF binding, which
// left it in the kernel's default routing context. Phase N1a moves
// every iface into its network's VRF; this test pins that contract.
//
// Strategy: replace `wg` and `ip` with recorder shims (re-using the
// approach in vrf_applier_test.go) and inspect the recorded `ip` argv
// for the bind call.

package sdwan

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// testWgPrivateKey is a syntactically valid WireGuard private key (32
// zero bytes, standard base64) — IMP-82208d22fdd1's validateWgPrivateKey
// rejects anything that isn't 32 raw bytes once decoded, so an arbitrary
// placeholder string like the old "fakeprivkey=" no longer reaches
// ApplyInterface's shell-out steps at all.
const testWgPrivateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

// newWgRecorderShims returns fake `ip`/`wg` binaries plus:
//   - ipLog / wgLog: every invocation's argv, one line each.
//   - linkStatePath: IMP-82208d22fdd1 — pre-seed this (via
//     writeWgLinkState) with the `ip -j link show <name>` JSON a real
//     kernel would report, to exercise ApplyInterface's idempotency
//     check. Empty/unseeded means "interface doesn't exist yet" (the
//     shim exits 1), matching readLinkState's safe nil-state fallback.
//   - wgPayloadLog: the content of the conf file passed to `wg
//     syncconf`/`setconf`, so tests can assert on which peers were
//     actually written without needing the (already-removed) temp file.
//   - routeV4Path / routeV6Path: IMP-470b28a77962 — pre-seed with the
//     `ip -4/-6 -j route show dev <name> proto static [vrf <vrf>]` JSON
//     a real kernel would report, to exercise reapStaleRoutes. Empty/
//     unseeded means "no routes of this family" (exit 1, empty stdout).
func newWgRecorderShims(t *testing.T) (ipBin, wgBin, ipLog, wgLog, linkStatePath, wgPayloadLog, routeV4Path, routeV6Path string) {
	t.Helper()

	dir := t.TempDir()
	ipBin = filepath.Join(dir, "ip")
	wgBin = filepath.Join(dir, "wg")
	ipLog = filepath.Join(dir, "ip-calls")
	wgLog = filepath.Join(dir, "wg-calls")
	state := filepath.Join(dir, "state")
	linkStatePath = filepath.Join(dir, "link-state.json")
	wgPayloadLog = filepath.Join(dir, "wg-payloads")
	routeV4Path = filepath.Join(dir, "route-state-v4.json")
	routeV6Path = filepath.Join(dir, "route-state-v6.json")

	for _, p := range []string{ipLog, wgLog, state, linkStatePath, wgPayloadLog, routeV4Path, routeV6Path} {
		if err := os.WriteFile(p, []byte(""), 0o644); err != nil {
			t.Fatalf("seed %s: %v", p, err)
		}
	}

	ipScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "$@" >> %q
case "$*" in
    "-4 -j route show "*)
        # IMP-470b28a77962: reapStaleRoutes' IPv4 source. A seed file
        # starting with "ERROR:" simulates a genuine `+"`"+`ip`+"`"+` failure — nonzero
        # exit WITH nonempty output — as opposed to an empty/unseeded
        # file, which means "no routes" (exit 1, empty stdout).
        if [ -s %q ]; then
            cat %q
            if head -c6 %q | grep -q "^ERROR:"; then
                exit 1
            fi
            exit 0
        fi
        exit 1
        ;;
    "-6 -j route show "*)
        # IMP-470b28a77962: reapStaleRoutes' IPv6 source. See -4 above.
        if [ -s %q ]; then
            cat %q
            if head -c6 %q | grep -q "^ERROR:"; then
                exit 1
            fi
            exit 0
        fi
        exit 1
        ;;
    "-j link show "*)
        # IMP-82208d22fdd1: readLinkState's source. Unseeded (empty
        # file) => "not found" (exit 1), matching state == nil.
        if [ -s %q ]; then
            cat %q
            exit 0
        fi
        exit 1
        ;;
    "link show "*)
        target="${@: -1}"
        if grep -q "^$target$" %q; then
            exit 0
        fi
        exit 1
        ;;
    *)
        # Record success and (where applicable) update state for
        # subsequent linkExists checks.
        case "$1$2" in
            "linkadd")
                echo "$3" >> %q
                ;;
        esac
        exit 0
        ;;
esac
`, ipLog, routeV4Path, routeV4Path, routeV4Path, routeV6Path, routeV6Path, routeV6Path, linkStatePath, linkStatePath, state, state)

	wgScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "$@" >> %q
case "$1" in
    syncconf|setconf)
        {
            echo "=== $1 ==="
            cat "${@: -1}" 2>/dev/null
        } >> %q
        ;;
esac
exit 0
`, wgLog, wgPayloadLog)

	if err := os.WriteFile(ipBin, []byte(ipScript), 0o755); err != nil {
		t.Fatalf("write ip shim: %v", err)
	}
	if err := os.WriteFile(wgBin, []byte(wgScript), 0o755); err != nil {
		t.Fatalf("write wg shim: %v", err)
	}
	return
}

// writeWgLinkState seeds the fake `ip -j link show <name>` response.
// See newWgRecorderShims' doc for how ApplyInterface treats an
// unseeded/missing state (state == nil ⇒ always reissue).
func writeWgLinkState(t *testing.T, path string, mtu int, master string, up bool) {
	t.Helper()
	flags := `["POINTOPOINT","NOARP"]`
	if up {
		flags = `["POINTOPOINT","NOARP","UP","LOWER_UP"]`
	}
	blob := fmt.Sprintf(`[{"mtu":%d,"master":%q,"flags":%s}]`, mtu, master, flags)
	if err := os.WriteFile(path, []byte(blob), 0o644); err != nil {
		t.Fatalf("write link state: %v", err)
	}
}

// routeStateEntry seeds one line of a fake `ip -j route show` response.
// Fields map 1:1 onto routeShowEntry's JSON fields. Deliberately no
// zero-value defaults for Dev/Protocol/Metric — IMP-470b28a77962 review
// B1: real iproute2 always prints these when the listing ISN'T filtered
// on them (which is exactly what listSdwanRoutesOnDevice now does), so
// a realistic fixture must set them explicitly rather than rely on a
// convenient default the real command would never actually omit.
type routeStateEntry struct {
	Dst      string
	Dev      string
	Protocol string
	Metric   int
}

// writeRouteState seeds the fake `ip -4/-6 -j route show` response used
// by reapStaleRoutes. Deliberately accepts entries of ANY
// dev/protocol/metric combination — including ones that don't belong to
// this package at all — so tests can prove listSdwanRoutesOnDevice's
// own three-way Go-side filter (dev == ifname, protocol ==
// sdwanRouteProto, metric == sdwanRouteMetric) actually does something,
// against a realistic UNFILTERED listing (see route_applier.go's B1
// doc for why the command itself carries no dev/proto filter).
func writeRouteState(t *testing.T, path string, entries []routeStateEntry) {
	t.Helper()
	var b strings.Builder
	b.WriteString("[")
	for i, e := range entries {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `{"dst":%q,"dev":%q,"protocol":%q,"metric":%d,"flags":[]}`, e.Dst, e.Dev, e.Protocol, e.Metric)
	}
	b.WriteString("]")
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatalf("write route state: %v", err)
	}
}

// writeRouteListError seeds the fake `ip -4/-6 -j route show` response
// to simulate a genuine `ip` failure — nonzero exit WITH nonempty
// output — as opposed to an unseeded/empty file, which the shim (and
// listSdwanRoutesOnDevice) both treat as "no routes of this family".
// SF4: proves a listing failure aborts the WHOLE reap with zero deletes,
// rather than proceeding on partial information.
func writeRouteListError(t *testing.T, path, message string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("ERROR: "+message), 0o644); err != nil {
		t.Fatalf("write route list error: %v", err)
	}
}

func TestWgApplier_BindsIfaceToVRFOnCreate(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}

	ipBin, wgBin, ipLog, _, _, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-aaaa11",
		Address:    "fd00:abcd::1/128",
		ListenPort: 51820,
		MTU:        1420,
		VrfName:    "sdwan-aaaa11",
	}
	if err := a.ApplyInterface(context.Background(), cfg, nil, testWgPrivateKey); err != nil {
		t.Fatalf("apply: %v", err)
	}

	raw, err := os.ReadFile(ipLog)
	if err != nil {
		t.Fatalf("read ip log: %v", err)
	}
	calls := string(raw)

	wantBind := "link set wg-sdwan-aaaa11 master sdwan-aaaa11"
	if !strings.Contains(calls, wantBind) {
		t.Errorf("Phase N1a regression: expected %q in ip calls, got:\n%s", wantBind, calls)
	}
}

func TestWgApplier_NoBindWhenVrfNameEmpty(t *testing.T) {
	ipBin, wgBin, ipLog, _, _, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-bbbb22",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		// VrfName empty — static-routing networks may not have a VRF
		// allocated; the applier must not attempt the bind.
	}
	if err := a.ApplyInterface(context.Background(), cfg, nil, testWgPrivateKey); err != nil {
		t.Fatalf("apply: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	if strings.Contains(string(raw), "link set wg-sdwan-bbbb22 master") {
		t.Errorf("must not bind when VrfName empty, got:\n%s", string(raw))
	}
}

// TestWgApplier_RebindsOnMasterDrift is the IMP-82208d22fdd1 rewrite of
// what used to be TestWgApplier_BindIsIdempotent_RebindEveryReconcile.
// The old version asserted ≥2 bind calls across two identical applies,
// but never seeded `ip -j link show` state — so it passed purely via
// the state==nil "always reissue" fallback (see readLinkState's doc),
// not via any actual drift detection. It would have kept passing even
// if the master-match branch were deleted outright, which made it a
// vacuous regression guard against the very defect IMP-82208d22fdd1
// introduces a real fix for. This version seeds a genuinely-different
// master and asserts the self-correction it claims to pin.
func TestWgApplier_RebindsOnMasterDrift(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, linkStatePath, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-cccc33",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		VrfName:    "sdwan-cccc33",
	}
	// The kernel currently has this iface mastered by a DIFFERENT VRF
	// than cfg wants — e.g. left over from a network's VRF being
	// reassigned. MTU/up already match so only the master drift should
	// trigger a call.
	writeWgLinkState(t, linkStatePath, 1420, "sdwan-OLD-vrf", true)

	if err := a.ApplyInterface(context.Background(), cfg, nil, testWgPrivateKey); err != nil {
		t.Fatalf("apply: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	wantBind := "link set wg-sdwan-cccc33 master sdwan-cccc33"
	if !strings.Contains(string(raw), wantBind) {
		t.Errorf("expected self-correcting rebind to the CURRENT master, got %q missing from:\n%s", wantBind, raw)
	}
}

// TestWgApplier_BindsWhenMasterEmpty is drift case (c): the iface
// exists (state is non-nil, not the state==nil fallback) but has no
// master at all, and cfg now wants one.
func TestWgApplier_BindsWhenMasterEmpty(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, linkStatePath, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-iiii99",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		VrfName:    "sdwan-iiii99",
	}
	// Iface exists, already at the right MTU and up, but unmastered.
	writeWgLinkState(t, linkStatePath, 1420, "", true)

	if err := a.ApplyInterface(context.Background(), cfg, nil, testWgPrivateKey); err != nil {
		t.Fatalf("apply: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	wantBind := "link set wg-sdwan-iiii99 master sdwan-iiii99"
	if !strings.Contains(string(raw), wantBind) {
		t.Errorf("expected a bind when the iface exists but has no master yet, got %q missing from:\n%s", wantBind, raw)
	}
}

// TestWgApplier_ReissuesUpWhenLinkIsDown is drift case (a): MTU already
// matches, but the interface is administratively down (state.Up ==
// false) — e.g. something else brought it down between ticks. The
// mtu/up call must still be reissued to bring it back up, even though
// the MTU half of the comparison is already satisfied.
func TestWgApplier_ReissuesUpWhenLinkIsDown(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, linkStatePath, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-jjjj00",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		// No VrfName — isolates this test to the MTU/up branch only, so
		// a failure here can't be confused with the master-drift tests.
	}
	// MTU already correct, but the link is down.
	writeWgLinkState(t, linkStatePath, 1420, "", false)

	if err := a.ApplyInterface(context.Background(), cfg, nil, testWgPrivateKey); err != nil {
		t.Fatalf("apply: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	wantUp := "link set wg-sdwan-jjjj00 mtu 1420 up"
	if !strings.Contains(string(raw), wantUp) {
		t.Errorf("expected the mtu/up call to be reissued while the link is down even though MTU already matches, got %q missing from:\n%s", wantUp, raw)
	}
}

// --- IMP-82208d22fdd1 -------------------------------------------------
//
// The agent ran `wg setconf` on every reconcile tick with no drift
// check, which REPLACES the whole peer set — tearing down every
// session (latest-handshake resets to "now", rx/tx counters restart)
// even when nothing had changed. These three tests pin the fix:
// `wg syncconf` instead of `setconf` for the peer set (syncconf itself
// is the drift check, applied unconditionally), plus an explicit
// `readLinkState`-based drift check for the `ip link set` steps, which
// have no such built-in idempotency.

func TestWgApplier_FirstTimeCreationStillWorks(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, wgLog, _, wgPayloadLog, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-dddd44",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		VrfName:    "sdwan-dddd44",
	}
	peers := []PeerConf{{PublicKey: "peerkey1=", AllowedIPs: []string{"fd00::2/128"}}}

	if err := a.ApplyInterface(context.Background(), cfg, peers, testWgPrivateKey); err != nil {
		t.Fatalf("apply: %v", err)
	}

	ipCalls, _ := os.ReadFile(ipLog)
	if !strings.Contains(string(ipCalls), "link add wg-sdwan-dddd44 type wireguard") {
		t.Errorf("expected link add on first-time creation, got:\n%s", ipCalls)
	}
	if !strings.Contains(string(ipCalls), "link set wg-sdwan-dddd44 master sdwan-dddd44") {
		t.Errorf("expected the VRF master bind on first-time creation, got:\n%s", ipCalls)
	}
	if !strings.Contains(string(ipCalls), "link set wg-sdwan-dddd44 mtu 1420 up") {
		t.Errorf("expected the mtu/up call on first-time creation, got:\n%s", ipCalls)
	}

	wgCalls, _ := os.ReadFile(wgLog)
	if !strings.Contains(string(wgCalls), "syncconf wg-sdwan-dddd44") {
		t.Errorf("expected wg syncconf on first-time creation, got:\n%s", wgCalls)
	}
	if strings.Contains(string(wgCalls), "setconf") {
		t.Errorf("must never call wg setconf (replaces the whole peer set, resetting sessions), got:\n%s", wgCalls)
	}

	payload, _ := os.ReadFile(wgPayloadLog)
	if !strings.Contains(string(payload), "peerkey1=") {
		t.Errorf("expected the peer's public key in the synced conf, got:\n%s", payload)
	}
}

func TestWgApplier_IdempotentOnUnchangedConfig(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, wgLog, linkStatePath, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-eeee55",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		VrfName:    "sdwan-eeee55",
	}
	peers := []PeerConf{{PublicKey: "peerkey1=", AllowedIPs: []string{"fd00::2/128"}}}

	if err := a.ApplyInterface(context.Background(), cfg, peers, testWgPrivateKey); err != nil {
		t.Fatalf("apply 1: %v", err)
	}

	// Seed the fake `ip -j link show` response to reflect what a real
	// kernel would report after the first apply's own commands ran:
	// MTU/master/up all already converged to what cfg wants.
	writeWgLinkState(t, linkStatePath, 1420, "sdwan-eeee55", true)

	if err := a.ApplyInterface(context.Background(), cfg, peers, testWgPrivateKey); err != nil {
		t.Fatalf("apply 2: %v", err)
	}

	ipCalls, _ := os.ReadFile(ipLog)
	bindCount := strings.Count(string(ipCalls), "link set wg-sdwan-eeee55 master sdwan-eeee55")
	if bindCount != 1 {
		t.Errorf("expected exactly 1 master bind — no redundant reissue once state already matches — got %d in:\n%s", bindCount, ipCalls)
	}
	mtuCount := strings.Count(string(ipCalls), "link set wg-sdwan-eeee55 mtu 1420 up")
	if mtuCount != 1 {
		t.Errorf("expected exactly 1 mtu/up call — no redundant reissue once state already matches — got %d in:\n%s", mtuCount, ipCalls)
	}

	wgCalls, _ := os.ReadFile(wgLog)
	if strings.Contains(string(wgCalls), "setconf") {
		t.Errorf("must never call wg setconf, got:\n%s", wgCalls)
	}
	// syncconf is itself the drift check for the peer set, so calling it
	// again on an unchanged tick is fine — IMP-82208d22fdd1's fix is
	// that it's never `setconf`, not that `wg` must be skipped entirely.
}

func TestWgApplier_ConvergesOnPeerSetChange(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, _, wgLog, linkStatePath, wgPayloadLog, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-ffff66",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		VrfName:    "sdwan-ffff66",
	}
	peerOld := []PeerConf{{PublicKey: "oldpeer=", AllowedIPs: []string{"fd00::2/128"}}}

	if err := a.ApplyInterface(context.Background(), cfg, peerOld, testWgPrivateKey); err != nil {
		t.Fatalf("apply 1: %v", err)
	}
	writeWgLinkState(t, linkStatePath, 1420, "sdwan-ffff66", true)

	peerNew := []PeerConf{{PublicKey: "newpeer=", AllowedIPs: []string{"fd00::3/128"}}}
	if err := a.ApplyInterface(context.Background(), cfg, peerNew, testWgPrivateKey); err != nil {
		t.Fatalf("apply 2: %v", err)
	}

	wgCalls, _ := os.ReadFile(wgLog)
	if strings.Count(string(wgCalls), "syncconf") != 2 {
		t.Errorf("expected a syncconf call on each apply (it is the drift check for peers), got:\n%s", wgCalls)
	}

	payload, _ := os.ReadFile(wgPayloadLog)
	if !strings.Contains(string(payload), "newpeer=") {
		t.Errorf("expected the new peer's public key in the second synced conf, got:\n%s", payload)
	}
}

// TestWgApplier_PersistentKeepaliveCanBeClearedToZero pins the item-1
// regression from review: `wg syncconf` (unlike `setconf`) only changes
// an attribute when the conf file carries a value for it, so omitting
// the PersistentKeepalive line — which is what writeWgConfFile did
// before this fix, whenever the platform reported it as 0/nil — left
// the node's prior nonzero keepalive untouched forever.
func TestWgApplier_PersistentKeepaliveCanBeClearedToZero(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, _, _, linkStatePath, wgPayloadLog, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-gggg77",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		VrfName:    "sdwan-gggg77",
	}
	keepalive25 := 25
	withKeepalive := []PeerConf{{
		PublicKey: "peerkey1=", AllowedIPs: []string{"fd00::2/128"},
		PersistentKeepalive: &keepalive25,
	}}
	if err := a.ApplyInterface(context.Background(), cfg, withKeepalive, testWgPrivateKey); err != nil {
		t.Fatalf("apply 1: %v", err)
	}
	writeWgLinkState(t, linkStatePath, 1420, "sdwan-gggg77", true)

	// The platform now reports no keepalive at all.
	cleared := []PeerConf{{
		PublicKey: "peerkey1=", AllowedIPs: []string{"fd00::2/128"},
		PersistentKeepalive: nil,
	}}
	if err := a.ApplyInterface(context.Background(), cfg, cleared, testWgPrivateKey); err != nil {
		t.Fatalf("apply 2: %v", err)
	}

	payload, _ := os.ReadFile(wgPayloadLog)
	parts := strings.Split(string(payload), "=== syncconf ===")
	if len(parts) < 3 {
		t.Fatalf("expected 2 syncconf payloads, got:\n%s", payload)
	}
	second := parts[2]
	if !strings.Contains(second, "PersistentKeepalive = 0") {
		t.Errorf("expected the second synced conf to explicitly clear keepalive to 0, got:\n%s", second)
	}
}

// TestWgApplier_MalformedPrivateKeyErrorDoesNotLeakTheKey pins item 4:
// a private key that fails validateWgPrivateKey must never appear in
// the returned error text (which flows into the manager's recordError
// and out through the heartbeat).
func TestWgApplier_MalformedPrivateKeyErrorDoesNotLeakTheKey(t *testing.T) {
	a := &ShellApplier{}
	cfg := InterfaceConf{Name: "wg-sdwan-hhhh88", Address: "fd00::1/128", ListenPort: 51820, MTU: 1420}
	badKey := "not-a-real-wireguard-key"

	err := a.ApplyInterface(context.Background(), cfg, nil, badKey)
	if err == nil {
		t.Fatal("expected an error for a malformed private key")
	}
	if strings.Contains(err.Error(), badKey) {
		t.Errorf("error must not contain the private key value, got: %v", err)
	}
}

// --- IMP-470b28a77962 --------------------------------------------------
//
// The agent never installed a kernel route for a peer's AllowedIPs, so
// a completed WireGuard handshake still left overlay traffic beyond the
// peer's own /128 with "Network is unreachable". These tests exercise
// ApplyRoutes directly (NOT ApplyInterface — review round B2 split them
// apart; see ApplyRoutes' own doc). Fixtures use documentation-only
// prefixes (RFC 5737 / RFC 3849), never the live fd-prefixed overlay.

// TestWgApplier_InstallsRoutesForEveryAllowedIP is contract (a): every
// AllowedIPs entry across every peer gets its own route, in both
// families, with the documented vrf/dev/proto/metric.
func TestWgApplier_InstallsRoutesForEveryAllowedIP(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, _, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{Name: "wg-sdwan-kkkk11", VrfName: "sdwan-kkkk11"}
	peers := []PeerConf{
		{PublicKey: "peer1=", AllowedIPs: []string{"2001:db8:1::/64"}},
		{PublicKey: "peer2=", AllowedIPs: []string{"192.0.2.0/24", "2001:db8:2::/64"}},
	}

	if err := a.ApplyRoutes(context.Background(), cfg, peers); err != nil {
		t.Fatalf("apply routes: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	calls := string(raw)
	for _, want := range []string{
		"-6 route replace 2001:db8:1::/64 dev wg-sdwan-kkkk11 vrf sdwan-kkkk11 proto 241 metric 1024",
		"-4 route replace 192.0.2.0/24 dev wg-sdwan-kkkk11 vrf sdwan-kkkk11 proto 241 metric 1024",
		"-6 route replace 2001:db8:2::/64 dev wg-sdwan-kkkk11 vrf sdwan-kkkk11 proto 241 metric 1024",
	} {
		if !strings.Contains(calls, want) {
			t.Errorf("expected %q, missing from:\n%s", want, calls)
		}
	}
}

// TestWgApplier_RoutesReissuedOnEveryApply is contract (b): calling
// ApplyRoutes repeatedly reissues `route replace` every time — there is
// no drift-skip inside ApplyRoutes itself (unlike ApplyInterface's
// link/master/MTU steps), because `ip route replace` is already
// idempotent at the kernel level, and because the manager calls this as
// its own step on EVERY tick regardless of what ApplyInterface's
// link-drift guard decided (see manager.go's apply_routes step and
// TestRouteFailureDoesNotBlockPeerReportsOrEgress for the integration-
// level half of this guarantee).
func TestWgApplier_RoutesReissuedOnEveryApply(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, _, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{Name: "wg-sdwan-llll21", VrfName: "sdwan-llll21"}
	peers := []PeerConf{{PublicKey: "peer1=", AllowedIPs: []string{"2001:db8:3::/64"}}}

	if err := a.ApplyRoutes(context.Background(), cfg, peers); err != nil {
		t.Fatalf("apply routes 1: %v", err)
	}
	if err := a.ApplyRoutes(context.Background(), cfg, peers); err != nil {
		t.Fatalf("apply routes 2: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	want := "route replace 2001:db8:3::/64 dev wg-sdwan-llll21 vrf sdwan-llll21 proto 241 metric 1024"
	count := strings.Count(string(raw), want)
	if count != 2 {
		t.Errorf("expected the route replace call on both applies, got %d in:\n%s", count, raw)
	}
}

// TestWgApplier_ReapsOnlyOwnedStaleRoutes is contract (c), core case:
// reaping deletes a stale route this package owns (proto 241, dev, and
// metric all matching), but never a still-desired one, and never a
// route that merely shares ONE of proto/dev/metric with what this
// package installs — review round SF4's explicit ask that a
// same-dst-different-proto-or-metric entry survive. Fixtures are
// REALISTIC per B1: dev/protocol/metric are always present, since the
// listing command itself no longer filters on any of them.
func TestWgApplier_ReapsOnlyOwnedStaleRoutes(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, _, _, _, routeV6Path := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{Name: "wg-sdwan-llll22", VrfName: "sdwan-llll22"}
	peers := []PeerConf{{PublicKey: "peer1=", AllowedIPs: []string{"2001:db8:5::/64"}}}

	writeRouteState(t, routeV6Path, []routeStateEntry{
		// Still desired — owned by this package (dev/proto/metric all
		// match) — must survive.
		{Dst: "2001:db8:5::/64", Dev: "wg-sdwan-llll22", Protocol: "241", Metric: 1024},
		// Stale, owned by this package — must be reaped.
		{Dst: "2001:db8:6::/64", Dev: "wg-sdwan-llll22", Protocol: "241", Metric: 1024},
		// Same dst as a "stale" entry could be, but proto is an
		// operator's static route, not ours — dev matches, proto
		// doesn't. Must survive.
		{Dst: "2001:db8:7::/64", Dev: "wg-sdwan-llll22", Protocol: "static", Metric: 1024},
		// Our proto+dev, but a DIFFERENT metric — not something
		// replaceRoute itself installed. Must survive (SF1/SF4).
		{Dst: "2001:db8:8::/64", Dev: "wg-sdwan-llll22", Protocol: "241", Metric: 100},
		// Our proto+metric, but on a DIFFERENT device entirely (e.g.
		// another SDWAN network sharing this VRF). Must survive.
		{Dst: "2001:db8:9::/64", Dev: "wg-sdwan-OTHER", Protocol: "241", Metric: 1024},
	})

	if err := a.ApplyRoutes(context.Background(), cfg, peers); err != nil {
		t.Fatalf("apply routes: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	calls := string(raw)
	if !strings.Contains(calls, "route del 2001:db8:6::/64 dev wg-sdwan-llll22") {
		t.Errorf("expected the stale, package-owned route to be reaped, missing from:\n%s", calls)
	}
	for _, mustSurvive := range []string{
		"route del 2001:db8:5::/64", // still desired
		"route del 2001:db8:7::/64", // proto mismatch
		"route del 2001:db8:8::/64", // metric mismatch
		"route del 2001:db8:9::/64", // dev mismatch
	} {
		if strings.Contains(calls, mustSurvive) {
			t.Errorf("must not delete a route that isn't a stale, package-owned one (%q), got:\n%s", mustSurvive, calls)
		}
	}
}

// TestWgApplier_ReapHandlesBareHostAddressAndDefaultRoute is SF4: a
// host route (the hub's real /128 case) prints from `ip -j route show`
// as a bare address with no "/n" suffix, and the default route prints
// as the literal string "default" — both must parse correctly, and a
// stale default route must be reapable (SF3), not silently invisible.
func TestWgApplier_ReapHandlesBareHostAddressAndDefaultRoute(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, _, _, _, routeV6Path := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{Name: "wg-sdwan-hhhh55", VrfName: "sdwan-hhhh55"}
	// The hub's real case: a single peer's own /128.
	peers := []PeerConf{{PublicKey: "hub=", AllowedIPs: []string{"2001:db8:ffff::1/128"}}}

	writeRouteState(t, routeV6Path, []routeStateEntry{
		// Still-desired /128, rendered WITHOUT a "/128" suffix — exactly
		// how `ip -j route show` prints a host route.
		{Dst: "2001:db8:ffff::1", Dev: "wg-sdwan-hhhh55", Protocol: "241", Metric: 1024},
		// A stale default route this package once installed.
		{Dst: "default", Dev: "wg-sdwan-hhhh55", Protocol: "241", Metric: 1024},
	})

	if err := a.ApplyRoutes(context.Background(), cfg, peers); err != nil {
		t.Fatalf("apply routes: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	calls := string(raw)
	if strings.Contains(calls, "route del 2001:db8:ffff::1") {
		t.Errorf("must not delete the still-desired bare-address host route, got:\n%s", calls)
	}
	if !strings.Contains(calls, "route del ::/0 dev wg-sdwan-hhhh55") {
		t.Errorf("expected the stale \"default\" entry to be reaped as ::/0, got:\n%s", calls)
	}
}

// TestWgApplier_ListingFailureDeletesNothing is SF4: when listing this
// device's routes genuinely fails (nonzero exit WITH output — not the
// empty-output/no-routes case), reaping must abort entirely rather than
// proceed on a partial or absent view of what's actually installed.
func TestWgApplier_ListingFailureDeletesNothing(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, _, _, routeV4Path, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{Name: "wg-sdwan-iiii66", VrfName: "sdwan-iiii66"}
	peers := []PeerConf{{PublicKey: "peer1=", AllowedIPs: []string{"192.0.2.0/24"}}}

	writeRouteListError(t, routeV4Path, "Error: Table does not exist.")

	err := a.ApplyRoutes(context.Background(), cfg, peers)
	if err == nil {
		t.Fatal("expected an error when the route listing itself fails")
	}

	raw, _ := os.ReadFile(ipLog)
	if strings.Contains(string(raw), "route del") {
		t.Errorf("a failed listing must delete NOTHING, got:\n%s", raw)
	}
	// The desired route install (independent of the listing/reap path)
	// still happened — a listing failure only aborts the reap half.
	if !strings.Contains(string(raw), "route replace 192.0.2.0/24 dev wg-sdwan-iiii66 vrf sdwan-iiii66 proto 241 metric 1024") {
		t.Errorf("expected the install half to still run despite the reap-side listing failure, got:\n%s", raw)
	}
}

// TestWgApplier_MasksHostBitsInsteadOfRejecting is contract (d), review
// round SF2: an AllowedIPs entry with host bits set is MASKED (not
// rejected) before it reaches argv — WireGuard's own cryptokey routing
// masks AllowedIPs the same way, so the installed route has to match
// what's actually reachable through the tunnel.
func TestWgApplier_MasksHostBitsInsteadOfRejecting(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, _, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{Name: "wg-sdwan-mmmm33", VrfName: "sdwan-mmmm33"}
	// Host bits set — not masked as sent by the platform.
	peers := []PeerConf{{PublicKey: "peer1=", AllowedIPs: []string{"2001:db8:9::5/64"}}}

	if err := a.ApplyRoutes(context.Background(), cfg, peers); err != nil {
		t.Fatalf("apply routes: %v (host bits must be masked, not rejected)", err)
	}

	raw, _ := os.ReadFile(ipLog)
	calls := string(raw)
	if !strings.Contains(calls, "route replace 2001:db8:9::/64 dev wg-sdwan-mmmm33 vrf sdwan-mmmm33 proto 241 metric 1024") {
		t.Errorf("expected the MASKED destination to be installed, got:\n%s", calls)
	}
	if strings.Contains(calls, "2001:db8:9::5") {
		t.Errorf("the unmasked, host-bit-set form must never reach argv, got:\n%s", calls)
	}
}

// TestWgApplier_SkipsInvalidAllowedIPEntriesIndividually pins the two
// cases SF2 explicitly kept as outright rejections (parse failure and
// an IPv4-mapped IPv6 address) — each skipped individually, without
// blocking a valid sibling entry in the same apply.
func TestWgApplier_SkipsInvalidAllowedIPEntriesIndividually(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, _, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{Name: "wg-sdwan-nnnn44", VrfName: "sdwan-nnnn44"}
	peers := []PeerConf{{PublicKey: "peer1=", AllowedIPs: []string{
		"not-a-cidr",
		"::ffff:192.0.2.1/128", // IPv4-mapped IPv6 — still rejected
		"2001:db8:10::/64",     // valid sibling
	}}}

	err := a.ApplyRoutes(context.Background(), cfg, peers)
	if err == nil {
		t.Fatal("expected an error reporting the invalid entries")
	}

	raw, _ := os.ReadFile(ipLog)
	calls := string(raw)
	if strings.Contains(calls, "not-a-cidr") || strings.Contains(calls, "192.0.2.1") {
		t.Errorf("an invalid entry must never reach argv, got:\n%s", calls)
	}
	if !strings.Contains(calls, "route replace 2001:db8:10::/64 dev wg-sdwan-nnnn44 vrf sdwan-nnnn44 proto 241 metric 1024") {
		t.Errorf("the valid sibling must still be installed despite the others' rejection, got:\n%s", calls)
	}
}

// TestWgApplier_SkipsRoutesEntirelyWhenVrfEmpty is contract (e), review
// round B3 (BLOCKER): with no VRF, ApplyRoutes must issue ZERO `ip`
// commands — installing/reaping in the MAIN table risks overwriting the
// node's own underlay routes (`ip route replace` matches on dst[+tos]+
// metric, not dev, so a peer AllowedIPs entry colliding with the
// node's default route or connected LAN route at the same metric would
// silently replace it — see route_applier.go's B3 doc for the full
// scenario). This replaces the old "main table, no vrf clause" version
// of this test, which is no longer the decided behavior.
func TestWgApplier_SkipsRoutesEntirelyWhenVrfEmpty(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ipBin, wgBin, ipLog, _, _, _, _, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{Name: "wg-sdwan-oooo77"} // no VrfName
	peers := []PeerConf{{PublicKey: "peer1=", AllowedIPs: []string{"192.0.2.0/24"}}}

	if err := a.ApplyRoutes(context.Background(), cfg, peers); err != nil {
		t.Fatalf("apply routes: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	if strings.TrimSpace(string(raw)) != "" {
		t.Errorf("expected ZERO ip commands when VrfName is empty, got:\n%s", raw)
	}
}
