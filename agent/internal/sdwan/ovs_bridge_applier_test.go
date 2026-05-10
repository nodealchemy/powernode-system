// ovs_bridge_applier_test.go — unit tests for the Phase O2 Open
// vSwitch bridge applier.
//
// Strategy: fork the recorder-shim pattern from
// linux_bridge_applier_test, but install TWO fake binaries because
// the OVS applier shells out to both `ovs-vsctl` (bridge lifecycle)
// and `ip` (link up + addr reconcile). Both shims append to a shared
// call log prefixed with the binary name so tests can assert command
// ordering across binaries, e.g. `ovs-vsctl: --may-exist add-br ...`
// must appear BEFORE `ip: link set ... up` for that bridge.
//
// The shim emits canned data for the two read commands the applier
// uses:
//   - `ovs-vsctl list-br` reads <tempdir>/bridges (one bridge name
//     per line) and echoes the lines verbatim.
//   - `ip -j addr show dev <name>` reads <tempdir>/addrs/<name> (one
//     CIDR per line) and emits the JSON shape parseAddrShow expects.
// Every other invocation exits 0 so the applier sees a successful
// process for each shell-out — tests inspect the call log to verify
// the right commands ran in the right order. No root, no OVS
// installed, no netlink.

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

// newOvsRecorderBins installs fake `ovs-vsctl` AND `ip` binaries in
// tempdir. Both write to the same call log with a prefix so tests can
// distinguish (and assert on) which binary was invoked.
//
// Returns:
//   - ovsBin   — absolute path to the fake ovs-vsctl binary.
//   - ipBin    — absolute path to the fake ip binary.
//   - logPath  — shared call log; each line is "<bin>: <argv>".
//   - bridgesPath — backing file for `ovs-vsctl list-br` output.
//   - addrsDir — directory of per-iface CIDR fixtures consumed by
//     `ip -j addr show dev <name>`.
func newOvsRecorderBins(t *testing.T) (ovsBin, ipBin, logPath, bridgesPath, addrsDir string) {
	t.Helper()

	dir := t.TempDir()
	ovsBin = filepath.Join(dir, "ovs-vsctl")
	ipBin = filepath.Join(dir, "ip")
	logPath = filepath.Join(dir, "calls")
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

	// ovs-vsctl shim — handles `list-br` (read fixture) and any other
	// invocation (silent exit 0). The applier doesn't currently parse
	// any other ovs-vsctl output, so a no-op success is sufficient.
	ovsScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "ovs-vsctl: $*" >> %q
args="$*"
case "$args" in
    "list-br")
        # Echo the bridge names verbatim, one per line.
        cat %q
        ;;
    *)
        exit 0
        ;;
esac
`, logPath, bridgesPath)

	// ip shim — handles `-j addr show dev <name>` (read per-iface
	// fixture, emit JSON) and any other invocation (silent exit 0).
	// Mirrors the JSON shape parseAddrShow expects (ifname +
	// addr_info[*].family/local/prefixlen).
	ipScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "ip: $*" >> %q
args="$*"
case "$args" in
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
`, logPath, addrsDir)

	if err := os.WriteFile(ovsBin, []byte(ovsScript), 0o755); err != nil {
		t.Fatalf("write ovs shim: %v", err)
	}
	if err := os.WriteFile(ipBin, []byte(ipScript), 0o755); err != nil {
		t.Fatalf("write ip shim: %v", err)
	}
	return
}

func writeOvsBridges(t *testing.T, bridgesPath string, names []string) {
	t.Helper()
	sort.Strings(names)
	body := strings.Join(names, "\n") + "\n"
	if err := os.WriteFile(bridgesPath, []byte(body), 0o644); err != nil {
		t.Fatalf("write bridges: %v", err)
	}
}

func writeOvsBridgeAddrs(t *testing.T, addrsDir, ifname string, cidrs []string) {
	t.Helper()
	body := strings.Join(cidrs, "\n") + "\n"
	if err := os.WriteFile(filepath.Join(addrsDir, ifname), []byte(body), 0o644); err != nil {
		t.Fatalf("write addrs: %v", err)
	}
}

func ovsReadCalls(t *testing.T, logPath string) string {
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

func TestOvsBridgeApplier_CreatesMissingBridge(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ovsBin, ipBin, logPath, _, _ := newOvsRecorderBins(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "ovs"},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	wantCreate := "ovs-vsctl: --may-exist add-br pwnbr-1"
	if !strings.Contains(calls, wantCreate) {
		t.Errorf("expected %q in calls, got:\n%s", wantCreate, calls)
	}
}

func TestOvsBridgeApplier_IsIdempotent(t *testing.T) {
	// Bridge AND its address already match desired; second Apply must
	// produce no add-br / del-br / addr add / addr del. Bring-up still
	// happens (idempotent on the kernel side) — same contract as the
	// Linux applier.
	ovsBin, ipBin, logPath, bridgesPath, addrsDir := newOvsRecorderBins(t)
	writeOvsBridges(t, bridgesPath, []string{"pwnbr-1"})
	writeOvsBridgeAddrs(t, addrsDir, "pwnbr-1", []string{"192.168.250.1/24"})
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "ovs", Cidrs: []string{"192.168.250.1/24"}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	// Note: --may-exist makes ovs-vsctl idempotent at the OVS layer,
	// so we always issue add-br. The contract is "no NEW work is done"
	// at the OVS layer, not "no calls are made" — but specifically we
	// must NOT del-br anything, and must NOT addr add/del.
	if strings.Contains(calls, "ovs-vsctl: --if-exists del-br pwnbr-1") {
		t.Errorf("expected NO del-br for converged bridge, got:\n%s", calls)
	}
	if strings.Contains(calls, "ip: addr add 192.168.250.1/24") {
		t.Errorf("expected NO addr add for existing address, got:\n%s", calls)
	}
	if strings.Contains(calls, "ip: addr del") {
		t.Errorf("expected NO addr del for converged state, got:\n%s", calls)
	}
	if !strings.Contains(calls, "ip: link set pwnbr-1 up") {
		t.Errorf("expected bring-up call, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_SetsMTUWhenSpecified(t *testing.T) {
	ovsBin, ipBin, logPath, _, _ := newOvsRecorderBins(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-9999", Kind: "ovs", MTU: 9000},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	wantMTU := "ovs-vsctl: set Interface pwnbr-9999 mtu_request=9000"
	if !strings.Contains(calls, wantMTU) {
		t.Errorf("expected %q in calls, got:\n%s", wantMTU, calls)
	}
	// Defensive: the OVS applier must NOT issue `ip link set ... mtu N` —
	// MTU is owned by mtu_request so the value persists in the OVS DB
	// across ovs-vswitchd restarts.
	if strings.Contains(calls, "ip: link set pwnbr-9999 mtu") {
		t.Errorf("ovs applier must use mtu_request, not `ip link set mtu`, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_OmitsMTUWhenZero(t *testing.T) {
	ovsBin, ipBin, logPath, _, _ := newOvsRecorderBins(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "ovs", MTU: 0},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	if strings.Contains(calls, "mtu_request") {
		t.Errorf("expected no mtu_request when MTU=0, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_BringsBridgeUp(t *testing.T) {
	ovsBin, ipBin, logPath, _, _ := newOvsRecorderBins(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{{Name: "pwnbr-99", Kind: "ovs"}}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	wantUp := "ip: link set pwnbr-99 up"
	if !strings.Contains(calls, wantUp) {
		t.Errorf("expected %q in calls, got:\n%s", wantUp, calls)
	}
}

func TestOvsBridgeApplier_AddsMissingAddresses(t *testing.T) {
	ovsBin, ipBin, logPath, bridgesPath, _ := newOvsRecorderBins(t)
	// Bridge already exists in OVS; address is not yet on the kernel iface.
	writeOvsBridges(t, bridgesPath, []string{"pwnbr-1"})
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "ovs", Cidrs: []string{"192.168.250.1/24"}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	wantAddr := "ip: addr add 192.168.250.1/24 dev pwnbr-1"
	if !strings.Contains(calls, wantAddr) {
		t.Errorf("expected %q in calls, got:\n%s", wantAddr, calls)
	}
}

func TestOvsBridgeApplier_RemovesOrphanAddresses(t *testing.T) {
	ovsBin, ipBin, logPath, bridgesPath, addrsDir := newOvsRecorderBins(t)
	writeOvsBridges(t, bridgesPath, []string{"pwnbr-1"})
	writeOvsBridgeAddrs(t, addrsDir, "pwnbr-1", []string{
		"192.168.250.1/24",
		"192.168.251.1/24",
	})
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "ovs", Cidrs: []string{"192.168.250.1/24"}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	wantDel := "ip: addr del 192.168.251.1/24 dev pwnbr-1"
	if !strings.Contains(calls, wantDel) {
		t.Errorf("expected orphan address removal %q, got:\n%s", wantDel, calls)
	}
	if strings.Contains(calls, "ip: addr del 192.168.250.1/24") {
		t.Errorf("must not delete desired address, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_ReapsOrphanBridges(t *testing.T) {
	ovsBin, ipBin, logPath, bridgesPath, _ := newOvsRecorderBins(t)
	// Two `pwnbr-*` OVS bridges exist; only one is desired. The
	// other must get del-br'd.
	writeOvsBridges(t, bridgesPath, []string{
		"pwnbr-1",
		"pwnbr-99",
	})
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "ovs"},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	if !strings.Contains(calls, "ovs-vsctl: --if-exists del-br pwnbr-99") {
		t.Errorf("expected orphan reap of pwnbr-99, got:\n%s", calls)
	}
	if strings.Contains(calls, "ovs-vsctl: --if-exists del-br pwnbr-1") {
		t.Errorf("expected NO del-br of desired bridge, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_LeavesNonPwnbrBridgesAlone(t *testing.T) {
	ovsBin, ipBin, logPath, bridgesPath, _ := newOvsRecorderBins(t)
	// Mix of platform-owned + foreign OVS bridges. Only pwnbr-* may
	// be touched; the rest must be invisible to the reaper.
	writeOvsBridges(t, bridgesPath, []string{
		"pwnbr-1",
		"br-int", // operator-installed (e.g. OVN integration bridge)
		"br-ex",  // operator-installed external bridge
		"ovsbr0", // operator-named OVS bridge
	})
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "ovs"},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	for _, forbidden := range []string{
		"--if-exists del-br br-int",
		"--if-exists del-br br-ex",
		"--if-exists del-br ovsbr0",
	} {
		if strings.Contains(calls, forbidden) {
			t.Errorf("must NOT touch non-pwnbr bridges, found %q in:\n%s", forbidden, calls)
		}
	}
}

func TestOvsBridgeApplier_SkipsEntriesWithLinuxKind(t *testing.T) {
	// Inverse of LinuxBridgeApplier's filter. Kind="linux" entries
	// belong to the Linux applier; the OVS applier must leave them
	// alone so the two backends don't race on the same DesiredBridge.
	ovsBin, ipBin, logPath, _, _ := newOvsRecorderBins(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-lin1", Kind: "linux"}, // skipped by OVS applier
		{Name: "pwnbr-ovs1", Kind: "ovs"},   // applied
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	if strings.Contains(calls, "add-br pwnbr-lin1") {
		t.Errorf("OVS applier must NOT touch kind=linux bridges, got:\n%s", calls)
	}
	if !strings.Contains(calls, "ovs-vsctl: --may-exist add-br pwnbr-ovs1") {
		t.Errorf("expected ovs entry to be applied, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_SkipsEntriesWithEmptyKind(t *testing.T) {
	// Empty Kind defaults to Linux per the platform compiler — so the
	// OVS applier must NOT touch it. This is the inverse of
	// TestLinuxBridgeApplier_AcceptsEmptyKind: the Linux applier
	// accepts empty-kind, the OVS applier rejects it. Together the two
	// rules partition the bridge namespace cleanly.
	ovsBin, ipBin, logPath, _, _ := newOvsRecorderBins(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-1"},              // Kind unset → linux → skipped here
		{Name: "pwnbr-2", Kind: "ovs"}, // applied
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	if strings.Contains(calls, "add-br pwnbr-1") {
		t.Errorf("OVS applier must NOT touch empty-kind bridges, got:\n%s", calls)
	}
	if !strings.Contains(calls, "ovs-vsctl: --may-exist add-br pwnbr-2") {
		t.Errorf("expected ovs entry to be applied, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_SkipsEntriesWithEmptyName(t *testing.T) {
	// Defensive — the platform's allocator should never emit an empty
	// name, but skipping is safer than handing "" to ovs-vsctl which
	// would be a hard syntax error from the OVS side.
	ovsBin, ipBin, logPath, _, _ := newOvsRecorderBins(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "", Kind: "ovs"},        // skipped
		{Name: "pwnbr-1", Kind: "ovs"}, // applied
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	if !strings.Contains(calls, "ovs-vsctl: --may-exist add-br pwnbr-1") {
		t.Errorf("expected pwnbr-1 to still be applied, got:\n%s", calls)
	}
	// The empty-name entry would surface in the argv echo as either
	// "add-br" with no trailing argument (line ends right after "add-br")
	// or "add-br " followed by a newline. Walk lines explicitly so the
	// only legitimate "add-br pwnbr-1" line doesn't false-positive a
	// substring scan.
	for _, line := range strings.Split(calls, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "ovs-vsctl: --may-exist add-br" ||
			trimmed == "ovs-vsctl: --may-exist add-br " {
			t.Errorf("expected NO empty-name bridge add, got line %q in:\n%s", line, calls)
		}
	}
}

func TestOvsBridgeApplier_ReturnsErrorWhenOvsVsctlMissing(t *testing.T) {
	// Simulate a host that has stamped a Kind="ovs" bridge but
	// doesn't have OVS installed. The applier must surface a clear
	// error rather than crash with "exec: not found" or silently
	// no-op. This is the "shouldn't happen" path — the platform's
	// network_profile check should prevent it — but defensive.
	a := &ShellOvsBridgeApplier{
		OvsVsctlBin: "/nonexistent/path/to/ovs-vsctl",
		IpBin:       "/usr/bin/true", // arbitrary; we never reach `ip` calls
	}

	desired := []DesiredBridge{{Name: "pwnbr-1", Kind: "ovs"}}
	err := a.Apply(context.Background(), desired)
	if err == nil {
		t.Fatalf("expected error when ovs-vsctl is missing, got nil")
	}
	if !strings.Contains(err.Error(), "ovs-vsctl") {
		t.Errorf("expected error to mention ovs-vsctl, got: %v", err)
	}
}

func TestOvsBridgeApplier_ToleratesMaxLengthName(t *testing.T) {
	// IFNAMSIZ is 15 chars usable. `pwnbr-` is 6 chars; the longest
	// short_id we can append is 9 chars → "pwnbr-abcdefghi" (15 chars).
	// OVS itself enforces the same kernel limit on internal port
	// names, so the boundary is identical to the Linux applier.
	ovsBin, ipBin, logPath, _, _ := newOvsRecorderBins(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	maxName := "pwnbr-abcdefghi" // exactly 15 chars
	if len(maxName) != 15 {
		t.Fatalf("test fixture broken: maxName has %d chars, want 15", len(maxName))
	}

	desired := []DesiredBridge{{Name: maxName, Kind: "ovs"}}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	wantCreate := "ovs-vsctl: --may-exist add-br " + maxName
	if !strings.Contains(calls, wantCreate) {
		t.Errorf("expected %q in calls, got:\n%s", wantCreate, calls)
	}
}

func TestOvsBridgeApplier_ApplyOrderingCreateBeforeUp(t *testing.T) {
	// Sanity: the bridge MUST be created (via ovs-vsctl) before we
	// try to bring it up (via ip). On a fresh host the `ip link set
	// up` would fail if the bridge didn't exist yet — so even though
	// the recorder shim returns 0 unconditionally, ordering is part
	// of the contract.
	ovsBin, ipBin, logPath, _, _ := newOvsRecorderBins(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{{Name: "pwnbr-ord", Kind: "ovs"}}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovsReadCalls(t, logPath)
	createIdx := strings.Index(calls, "ovs-vsctl: --may-exist add-br pwnbr-ord")
	upIdx := strings.Index(calls, "ip: link set pwnbr-ord up")
	if createIdx < 0 {
		t.Fatalf("missing create call:\n%s", calls)
	}
	if upIdx < 0 {
		t.Fatalf("missing bring-up call:\n%s", calls)
	}
	if createIdx > upIdx {
		t.Errorf("expected add-br before link-up; got create@%d, up@%d:\n%s",
			createIdx, upIdx, calls)
	}
}

// ----------------------------------------------------------------------
// parseListBr unit tests — exercised separately from the applier so
// the parsing logic is covered without invoking the shim. Mirrors the
// parseLinkShow / parseAddrShow tests for the Linux applier.
// ----------------------------------------------------------------------

func TestParseListBr_Empty(t *testing.T) {
	got := parseListBr("")
	if len(got) != 0 {
		t.Errorf("expected empty map, got %v", got)
	}
}

func TestParseListBr_SingleBridge(t *testing.T) {
	got := parseListBr("pwnbr-1\n")
	if _, ok := got["pwnbr-1"]; !ok {
		t.Errorf("expected pwnbr-1 in map, got %v", got)
	}
}

func TestParseListBr_FiltersForeignBridges(t *testing.T) {
	in := "pwnbr-1\nbr-int\npwnbr-99\nbr-ex\nplain-bridge\n"
	got := parseListBr(in)
	if _, ok := got["pwnbr-1"]; !ok {
		t.Errorf("expected pwnbr-1 in map, got %v", got)
	}
	if _, ok := got["pwnbr-99"]; !ok {
		t.Errorf("expected pwnbr-99 in map, got %v", got)
	}
	for _, foreign := range []string{"br-int", "br-ex", "plain-bridge"} {
		if _, ok := got[foreign]; ok {
			t.Errorf("foreign bridge %q must be filtered out, got map %v", foreign, got)
		}
	}
}

func TestParseListBr_TolerantOfBlankLinesAndWhitespace(t *testing.T) {
	in := "\npwnbr-1\n\n  pwnbr-2  \n\n"
	got := parseListBr(in)
	if _, ok := got["pwnbr-1"]; !ok {
		t.Errorf("expected pwnbr-1 in map, got %v", got)
	}
	if _, ok := got["pwnbr-2"]; !ok {
		t.Errorf("expected pwnbr-2 in map, got %v", got)
	}
	if len(got) != 2 {
		t.Errorf("expected exactly 2 entries, got %d: %v", len(got), got)
	}
}
