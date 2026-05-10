// linux_bridge_applier_test.go — unit tests for the Phase O1 Linux
// bridge applier.
//
// Strategy: replace the `ip` binary with a tiny shim shell script that
// records every invocation to a log file and emits canned JSON for the
// list-bridges + list-addrs reads. The applier sees a real process exit
// code; tests inspect the log to verify the right commands were issued
// in the right order. Same recorder-shim pattern as vrf_applier_test
// and vip_applier_test — no root, no netlink, no CAP_NET_ADMIN.

package sdwan

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// newBridgeRecorderIp installs a fake `ip` binary in tempdir that:
//   - logs all argv to <tempdir>/ip-calls
//   - emits JSON for `-d -j link show type bridge` from
//     <tempdir>/bridges (one ifname per line; emitted as bridge kind)
//   - emits JSON for `-j addr show dev <name>` from
//     <tempdir>/addrs/<name> (one CIDR per line)
//   - returns 0 for everything else (link add/set/delete, addr add/del)
//
// The shim only emits the JSON shapes the parsers care about — it
// drops every field except ifname + linkinfo.info_kind for bridges,
// and ifname + addr_info[*].family/local/prefixlen for addresses.
// This keeps the fixture deterministic and avoids drift if the kernel
// adds new fields.
func newBridgeRecorderIp(t *testing.T) (binPath, logPath, bridgesPath, addrsDir string) {
	t.Helper()

	dir := t.TempDir()
	binPath = filepath.Join(dir, "ip")
	logPath = filepath.Join(dir, "ip-calls")
	bridgesPath = filepath.Join(dir, "bridges")
	addrsDir = filepath.Join(dir, "addrs")

	if err := os.WriteFile(logPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed log: %v", err)
	}
	if err := os.WriteFile(bridgesPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed bridges: %v", err)
	}
	if err := os.MkdirAll(addrsDir, 0o755); err != nil {
		t.Fatalf("seed addrs: %v", err)
	}

	script := fmt.Sprintf(`#!/usr/bin/env bash
echo "$@" >> %q
args="$*"
case "$args" in
    "-d -j link show type bridge")
        # Build a JSON array of {ifname, linkinfo:{info_kind:"bridge"}}.
        first=1
        printf "["
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            if [ "$first" -eq 0 ]; then printf ","; fi
            printf '{"ifname":"%%s","linkinfo":{"info_kind":"bridge"}}' "$name"
            first=0
        done < %q
        printf "]"
        ;;
    "-j addr show dev "*)
        ifname="${args##* }"
        f="%s/$ifname"
        if [ -f "$f" ]; then
            printf '[{"ifname":"%%s","addr_info":[' "$ifname"
            first=1
            while IFS= read -r cidr; do
                [ -z "$cidr" ] && continue
                local_addr="${cidr%%/*}"
                prefix="${cidr##*/}"
                case "$cidr" in
                    *:*) family="inet6" ;;
                    *)   family="inet" ;;
                esac
                if [ "$first" -eq 0 ]; then printf ","; fi
                printf '{"family":"%%s","local":"%%s","prefixlen":%%s}' "$family" "$local_addr" "$prefix"
                first=0
            done < "$f"
            printf "]}]"
        fi
        ;;
    *)
        exit 0
        ;;
esac
`, logPath, bridgesPath, addrsDir)

	if err := os.WriteFile(binPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write shim: %v", err)
	}
	return
}

func writeBridges(t *testing.T, bridgesPath string, names []string) {
	t.Helper()
	sort.Strings(names)
	body := strings.Join(names, "\n") + "\n"
	if err := os.WriteFile(bridgesPath, []byte(body), 0o644); err != nil {
		t.Fatalf("write bridges: %v", err)
	}
}

func writeBridgeAddrs(t *testing.T, addrsDir, ifname string, cidrs []string) {
	t.Helper()
	body := strings.Join(cidrs, "\n") + "\n"
	if err := os.WriteFile(filepath.Join(addrsDir, ifname), []byte(body), 0o644); err != nil {
		t.Fatalf("write addrs: %v", err)
	}
}

func bridgeReadCalls(t *testing.T, logPath string) string {
	t.Helper()
	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read calls: %v", err)
	}
	return strings.TrimSpace(string(raw))
}

// ----------------------------------------------------------------------
// Apply contract tests
// ----------------------------------------------------------------------

func TestLinuxBridgeApplier_CreatesMissingBridge(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	binPath, logPath, _, _ := newBridgeRecorderIp(t)
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "linux"},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	wantCreate := "link add pwnbr-1 type bridge"
	if !strings.Contains(calls, wantCreate) {
		t.Errorf("expected %q in calls, got:\n%s", wantCreate, calls)
	}
}

func TestLinuxBridgeApplier_BringsBridgeUp(t *testing.T) {
	binPath, logPath, _, _ := newBridgeRecorderIp(t)
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{{Name: "pwnbr-99", Kind: "linux"}}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	wantUp := "link set pwnbr-99 up"
	if !strings.Contains(calls, wantUp) {
		t.Errorf("expected %q in calls, got:\n%s", wantUp, calls)
	}
}

func TestLinuxBridgeApplier_SetsMTUWhenSpecified(t *testing.T) {
	binPath, logPath, _, _ := newBridgeRecorderIp(t)
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "pwnbr-9999", Kind: "linux", MTU: 9000},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	wantMTU := "link set pwnbr-9999 mtu 9000"
	if !strings.Contains(calls, wantMTU) {
		t.Errorf("expected %q in calls, got:\n%s", wantMTU, calls)
	}
}

func TestLinuxBridgeApplier_OmitsMTUWhenZero(t *testing.T) {
	binPath, logPath, _, _ := newBridgeRecorderIp(t)
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "linux", MTU: 0},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	if strings.Contains(calls, "mtu") {
		t.Errorf("expected no `mtu` call when MTU=0, got:\n%s", calls)
	}
}

func TestLinuxBridgeApplier_AddsMissingAddresses(t *testing.T) {
	binPath, logPath, bridgesPath, _ := newBridgeRecorderIp(t)
	// Bridge already exists; address is not yet on it.
	writeBridges(t, bridgesPath, []string{"pwnbr-1"})
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "linux", Cidrs: []string{"192.168.250.1/24"}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	wantAddr := "addr add 192.168.250.1/24 dev pwnbr-1"
	if !strings.Contains(calls, wantAddr) {
		t.Errorf("expected %q in calls, got:\n%s", wantAddr, calls)
	}
}

func TestLinuxBridgeApplier_RemovesOrphanAddresses(t *testing.T) {
	binPath, logPath, bridgesPath, addrsDir := newBridgeRecorderIp(t)
	writeBridges(t, bridgesPath, []string{"pwnbr-1"})
	// Bridge has two addresses; only one is desired.
	writeBridgeAddrs(t, addrsDir, "pwnbr-1", []string{
		"192.168.250.1/24",
		"192.168.251.1/24",
	})
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "linux", Cidrs: []string{"192.168.250.1/24"}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	wantDel := "addr del 192.168.251.1/24 dev pwnbr-1"
	if !strings.Contains(calls, wantDel) {
		t.Errorf("expected orphan address removal %q, got:\n%s", wantDel, calls)
	}
	if strings.Contains(calls, "addr del 192.168.250.1/24") {
		t.Errorf("must not delete desired address, got:\n%s", calls)
	}
}

func TestLinuxBridgeApplier_IsIdempotent(t *testing.T) {
	binPath, logPath, bridgesPath, addrsDir := newBridgeRecorderIp(t)
	// Bridge AND its address already match desired.
	writeBridges(t, bridgesPath, []string{"pwnbr-1"})
	writeBridgeAddrs(t, addrsDir, "pwnbr-1", []string{"192.168.250.1/24"})
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "linux", Cidrs: []string{"192.168.250.1/24"}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	if strings.Contains(calls, "link add pwnbr-1") {
		t.Errorf("expected NO `link add` for existing bridge, got:\n%s", calls)
	}
	if strings.Contains(calls, "addr add 192.168.250.1/24") {
		t.Errorf("expected NO `addr add` for existing address, got:\n%s", calls)
	}
	if strings.Contains(calls, "addr del") {
		t.Errorf("expected NO `addr del` for converged state, got:\n%s", calls)
	}
	// Bring-up still happens (idempotent on the kernel side; cheap call).
	if !strings.Contains(calls, "link set pwnbr-1 up") {
		t.Errorf("expected bring-up call, got:\n%s", calls)
	}
}

func TestLinuxBridgeApplier_ReapsOrphanBridges(t *testing.T) {
	binPath, logPath, bridgesPath, _ := newBridgeRecorderIp(t)
	// Two `pwnbr-*` bridges exist; only one is desired. The other
	// must be deleted.
	writeBridges(t, bridgesPath, []string{
		"pwnbr-1",
		"pwnbr-99",
	})
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "linux"},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	if !strings.Contains(calls, "link delete pwnbr-99") {
		t.Errorf("expected orphan reap of pwnbr-99, got:\n%s", calls)
	}
	if strings.Contains(calls, "link delete pwnbr-1") {
		t.Errorf("expected NO delete of desired bridge, got:\n%s", calls)
	}
}

func TestLinuxBridgeApplier_LeavesNonPwnbrBridgesAlone(t *testing.T) {
	binPath, logPath, bridgesPath, _ := newBridgeRecorderIp(t)
	writeBridges(t, bridgesPath, []string{
		"pwnbr-1",
		"virbr0",  // libvirt default
		"docker0", // docker
		"pwnvbr0", // legacy manual setup
		"br0",     // operator bridge
	})
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "linux"},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	for _, forbidden := range []string{
		"link delete virbr0",
		"link delete docker0",
		"link delete pwnvbr0",
		"link delete br0",
	} {
		if strings.Contains(calls, forbidden) {
			t.Errorf("must NOT touch non-pwnbr bridges, found %q in:\n%s", forbidden, calls)
		}
	}
}

func TestLinuxBridgeApplier_ToleratesMaxLengthName(t *testing.T) {
	// IFNAMSIZ is 15 chars usable. `pwnbr-` is 6 chars; the longest
	// short_id we can append is 9 chars → "pwnbr-abcdefghi" (15 chars).
	binPath, logPath, _, _ := newBridgeRecorderIp(t)
	a := &LinuxBridgeApplier{IpBin: binPath}

	maxName := "pwnbr-abcdefghi" // exactly 15 chars
	if len(maxName) != 15 {
		t.Fatalf("test fixture broken: maxName has %d chars, want 15", len(maxName))
	}

	desired := []DesiredBridge{{Name: maxName, Kind: "linux"}}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	wantCreate := "link add " + maxName + " type bridge"
	if !strings.Contains(calls, wantCreate) {
		t.Errorf("expected %q in calls, got:\n%s", wantCreate, calls)
	}
}

func TestLinuxBridgeApplier_SkipsEntriesWithEmptyName(t *testing.T) {
	binPath, logPath, _, _ := newBridgeRecorderIp(t)
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "", Kind: "linux"}, // skipped
		{Name: "pwnbr-1", Kind: "linux"},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	// The empty-name entry must not generate any commands referencing
	// an empty operand. The simplest tell is "type bridge" appearing
	// without a name in front, but more robust: the desired entry
	// for pwnbr-1 must still be applied.
	if !strings.Contains(calls, "link add pwnbr-1 type bridge") {
		t.Errorf("expected pwnbr-1 to still be applied, got:\n%s", calls)
	}
	// Defensive: an `ip link add  type bridge` (double space from empty
	// name) would be the visible artifact of the bug we're guarding
	// against. The shim writes exactly the args it receives, so this
	// catches it.
	if strings.Contains(calls, "link add  type bridge") {
		t.Errorf("expected NO empty-name bridge add, got:\n%s", calls)
	}
}

func TestLinuxBridgeApplier_SkipsEntriesWithOvsKind(t *testing.T) {
	// Phase O2 will introduce kind="ovs" entries that an OvsBridgeApplier
	// will own. The Linux applier must skip them — on a heavyweight host
	// running both appliers (or during the migration), filtering by kind
	// is the only thing preventing both backends from racing on the same
	// bridge.
	binPath, logPath, _, _ := newBridgeRecorderIp(t)
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{
		{Name: "pwnbr-ovs1", Kind: "ovs"},   // skipped by Linux applier
		{Name: "pwnbr-lin1", Kind: "linux"}, // applied
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	if strings.Contains(calls, "link add pwnbr-ovs1") {
		t.Errorf("Linux applier must NOT touch kind=ovs bridges, got:\n%s", calls)
	}
	if !strings.Contains(calls, "link add pwnbr-lin1 type bridge") {
		t.Errorf("expected linux entry to be applied, got:\n%s", calls)
	}
}

func TestLinuxBridgeApplier_AcceptsEmptyKind(t *testing.T) {
	// Empty Kind is treated as "linux" (the default backend). This is
	// the wire-compat fallback for older platform compilers that
	// haven't started stamping the kind field yet.
	binPath, logPath, _, _ := newBridgeRecorderIp(t)
	a := &LinuxBridgeApplier{IpBin: binPath}

	desired := []DesiredBridge{{Name: "pwnbr-1"}} // Kind unset
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := bridgeReadCalls(t, logPath)
	if !strings.Contains(calls, "link add pwnbr-1 type bridge") {
		t.Errorf("expected empty-kind entry to be applied, got:\n%s", calls)
	}
}

// ----------------------------------------------------------------------
// JSON parser unit tests — exercised separately from the applier so
// the parsing logic is covered without invoking the shim.
// ----------------------------------------------------------------------

func TestParseLinkShow_Empty(t *testing.T) {
	got, err := parseLinkShow("")
	if err != nil {
		t.Fatalf("parse empty: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty map, got %v", got)
	}
}

func TestParseLinkShow_SingleBridge(t *testing.T) {
	in := `[{"ifname":"pwnbr-1","linkinfo":{"info_kind":"bridge"}}]`
	got, err := parseLinkShow(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got["pwnbr-1"] != "bridge" {
		t.Errorf("expected pwnbr-1=bridge, got %v", got)
	}
}

func TestParseLinkShow_MultipleBridges(t *testing.T) {
	in := `[
		{"ifname":"pwnbr-1","linkinfo":{"info_kind":"bridge"}},
		{"ifname":"pwnbr-99","linkinfo":{"info_kind":"bridge"}},
		{"ifname":"docker0","linkinfo":{"info_kind":"bridge"}}
	]`
	got, err := parseLinkShow(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got["pwnbr-1"] != "bridge" || got["pwnbr-99"] != "bridge" || got["docker0"] != "bridge" {
		t.Errorf("unexpected parse result: %v", got)
	}
}

func TestParseLinkShow_RoundTrip(t *testing.T) {
	// Real-world-ish fixture: kernel emits many fields we ignore. The
	// parser should pick out ifname + info_kind regardless. Mirrors the
	// shape of `ip -d -j link show type bridge` on a live kernel.
	in := `[{
		"ifindex": 3,
		"ifname": "pwnbr-1",
		"flags": ["BROADCAST","MULTICAST","UP","LOWER_UP"],
		"mtu": 1500,
		"qdisc": "noqueue",
		"operstate": "UP",
		"linkinfo": {
			"info_kind": "bridge",
			"info_data": {"forward_delay": 1500, "hello_time": 200}
		}
	}]`
	got, err := parseLinkShow(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(got) != 1 || got["pwnbr-1"] != "bridge" {
		t.Errorf("expected {pwnbr-1: bridge}, got %v", got)
	}
}

func TestParseAddrShow_Empty(t *testing.T) {
	got, err := parseAddrShow("")
	if err != nil {
		t.Fatalf("parse empty: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty map, got %v", got)
	}
}

func TestParseAddrShow_Mixed(t *testing.T) {
	in := `[{
		"ifname": "pwnbr-1",
		"addr_info": [
			{"family":"inet","local":"192.168.250.1","prefixlen":24},
			{"family":"inet6","local":"fd00::1","prefixlen":64}
		]
	}]`
	got, err := parseAddrShow(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("expected 2 addresses, got %d: %v", len(got), got)
	}
	// Keys are normalized; original CIDR is the value.
	v4Key, _ := normalizeCidr("192.168.250.1/24")
	v6Key, _ := normalizeCidr("fd00::1/64")
	if got[v4Key] != "192.168.250.1/24" {
		t.Errorf("v4 key %q missing: %v", v4Key, got)
	}
	if got[v6Key] != "fd00::1/64" {
		t.Errorf("v6 key %q missing: %v", v6Key, got)
	}
}
