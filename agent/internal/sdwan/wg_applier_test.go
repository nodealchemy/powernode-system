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
func newWgRecorderShims(t *testing.T) (ipBin, wgBin, ipLog, wgLog, linkStatePath, wgPayloadLog string) {
	t.Helper()

	dir := t.TempDir()
	ipBin = filepath.Join(dir, "ip")
	wgBin = filepath.Join(dir, "wg")
	ipLog = filepath.Join(dir, "ip-calls")
	wgLog = filepath.Join(dir, "wg-calls")
	state := filepath.Join(dir, "state")
	linkStatePath = filepath.Join(dir, "link-state.json")
	wgPayloadLog = filepath.Join(dir, "wg-payloads")

	for _, p := range []string{ipLog, wgLog, state, linkStatePath, wgPayloadLog} {
		if err := os.WriteFile(p, []byte(""), 0o644); err != nil {
			t.Fatalf("seed %s: %v", p, err)
		}
	}

	ipScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "$@" >> %q
case "$*" in
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
`, ipLog, linkStatePath, linkStatePath, state, state)

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

func TestWgApplier_BindsIfaceToVRFOnCreate(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}

	ipBin, wgBin, ipLog, _, _, _ := newWgRecorderShims(t)
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
	ipBin, wgBin, ipLog, _, _, _ := newWgRecorderShims(t)
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
	ipBin, wgBin, ipLog, _, linkStatePath, _ := newWgRecorderShims(t)
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
	ipBin, wgBin, ipLog, _, linkStatePath, _ := newWgRecorderShims(t)
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
	ipBin, wgBin, ipLog, _, linkStatePath, _ := newWgRecorderShims(t)
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
	ipBin, wgBin, ipLog, wgLog, _, wgPayloadLog := newWgRecorderShims(t)
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
	ipBin, wgBin, ipLog, wgLog, linkStatePath, _ := newWgRecorderShims(t)
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
	ipBin, wgBin, _, wgLog, linkStatePath, wgPayloadLog := newWgRecorderShims(t)
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
	ipBin, wgBin, _, _, linkStatePath, wgPayloadLog := newWgRecorderShims(t)
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
