// vrf_applier_test.go — unit tests for the Phase N1a Linux VRF applier.
//
// Strategy: replace the `ip` binary with a tiny shim shell script that
// records every invocation to a log file. The applier sees a real
// process exit code; the test inspects the log to verify the right
// commands were issued in the right order.
//
// We do NOT exercise real netlink — the runtime CI host doesn't have
// CAP_NET_ADMIN. The shim covers the contract surface without
// requiring root.

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

// newRecorderIp installs a fake `ip` binary in tempdir that:
//   - logs all argv to <tempdir>/ip-calls
//   - returns canned stdout for `link show type vrf` based on the
//     contents of <tempdir>/state.json (a simple "name:tableid" file)
//   - returns 0 for everything else
//
// Returns the binary path and the log file path.
func newRecorderIp(t *testing.T) (binPath, logPath, statePath string) {
	t.Helper()

	dir := t.TempDir()
	binPath = filepath.Join(dir, "ip")
	logPath = filepath.Join(dir, "ip-calls")
	statePath = filepath.Join(dir, "state.json")

	// Touch the log so cat of an absent file doesn't surprise the harness.
	if err := os.WriteFile(logPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed log: %v", err)
	}
	if err := os.WriteFile(statePath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed state: %v", err)
	}

	script := fmt.Sprintf(`#!/usr/bin/env bash
echo "$@" >> %q
case "$*" in
    *"link show type vrf"*|"-d -j link show type vrf")
        cat %q
        ;;
    *"link show "*)
        # The ShellApplier.linkExists check: success when the iface
        # name appears in state file, error otherwise.
        target_iface="${@: -1}"
        if grep -q "\"$target_iface\":" %q 2>/dev/null; then
            exit 0
        else
            exit 1
        fi
        ;;
    *)
        exit 0
        ;;
esac
`, logPath, statePath, statePath)

	if err := os.WriteFile(binPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write shim: %v", err)
	}
	return binPath, logPath, statePath
}

func readCalls(t *testing.T, logPath string) []string {
	t.Helper()
	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read calls: %v", err)
	}
	out := strings.Split(strings.TrimSpace(string(raw)), "\n")
	for i, s := range out {
		out[i] = strings.TrimSpace(s)
	}
	return out
}

func writeVRFState(t *testing.T, statePath string, vrfs map[string]int) {
	t.Helper()
	if len(vrfs) == 0 {
		_ = os.WriteFile(statePath, []byte(""), 0o644)
		return
	}
	// Build a deterministic JSON array shape that parseVRFLinkShow understands.
	names := make([]string, 0, len(vrfs))
	for n := range vrfs {
		names = append(names, n)
	}
	sort.Strings(names)
	var sb strings.Builder
	sb.WriteString("[")
	for i, n := range names {
		if i > 0 {
			sb.WriteString(",")
		}
		fmt.Fprintf(&sb, `{"ifname":%q,"linkinfo":{"info_kind":"vrf","info_data":{"table":%d}}}`, n, vrfs[n])
	}
	sb.WriteString("]")
	if err := os.WriteFile(statePath, []byte(sb.String()), 0o644); err != nil {
		t.Fatalf("write state: %v", err)
	}
}

func TestVRFApplier_CreatesMissingVRF(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	binPath, logPath, _ := newRecorderIp(t)
	a := &ShellVRFApplier{IpBin: binPath}

	desired := []DesiredVRF{
		{Name: "sdwan-aaaa1111", TableID: 100, NetworkHandle: "aaaa1111"},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := strings.Join(readCalls(t, logPath), "\n")
	wantCreate := "link add sdwan-aaaa1111 type vrf table 100"
	if !strings.Contains(calls, wantCreate) {
		t.Errorf("expected %q in calls, got:\n%s", wantCreate, calls)
	}
	wantUp := "link set sdwan-aaaa1111 up"
	if !strings.Contains(calls, wantUp) {
		t.Errorf("expected %q in calls, got:\n%s", wantUp, calls)
	}
}

func TestVRFApplier_IdempotentWhenVRFExistsWithSameTableID(t *testing.T) {
	binPath, logPath, statePath := newRecorderIp(t)
	writeVRFState(t, statePath, map[string]int{"sdwan-aaaa1111": 100})
	a := &ShellVRFApplier{IpBin: binPath}

	desired := []DesiredVRF{
		{Name: "sdwan-aaaa1111", TableID: 100},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := strings.Join(readCalls(t, logPath), "\n")
	if strings.Contains(calls, "link add sdwan-aaaa1111") {
		t.Errorf("expected NO `link add` for existing VRF, got:\n%s", calls)
	}
	// Bring-up still happens (idempotent on the kernel side).
	if !strings.Contains(calls, "link set sdwan-aaaa1111 up") {
		t.Errorf("expected bring-up call, got:\n%s", calls)
	}
}

func TestVRFApplier_RecreatesOnTableIDDrift(t *testing.T) {
	binPath, logPath, statePath := newRecorderIp(t)
	// Existing VRF has table 100; desired wants 200. Applier must
	// delete + recreate.
	writeVRFState(t, statePath, map[string]int{"sdwan-aaaa1111": 100})
	a := &ShellVRFApplier{IpBin: binPath}

	desired := []DesiredVRF{
		{Name: "sdwan-aaaa1111", TableID: 200},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := readCalls(t, logPath)
	hasDelete := false
	hasCreate := false
	deleteIdx := -1
	createIdx := -1
	for i, c := range calls {
		if strings.Contains(c, "link delete sdwan-aaaa1111") {
			hasDelete = true
			deleteIdx = i
		}
		if strings.Contains(c, "link add sdwan-aaaa1111 type vrf table 200") {
			hasCreate = true
			createIdx = i
		}
	}
	if !hasDelete || !hasCreate {
		t.Errorf("expected delete + recreate sequence, calls:\n%s", strings.Join(calls, "\n"))
	}
	if deleteIdx > createIdx {
		t.Errorf("expected delete BEFORE create, got delete=%d create=%d", deleteIdx, createIdx)
	}
}

func TestVRFApplier_ReapsOrphans(t *testing.T) {
	binPath, logPath, statePath := newRecorderIp(t)
	// Two VRFs exist; only one is desired. The other must be deleted.
	writeVRFState(t, statePath, map[string]int{
		"sdwan-aaaa1111": 100,
		"sdwan-bbbb2222": 101,
	})
	a := &ShellVRFApplier{IpBin: binPath}

	desired := []DesiredVRF{
		{Name: "sdwan-aaaa1111", TableID: 100},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := strings.Join(readCalls(t, logPath), "\n")
	if !strings.Contains(calls, "link delete sdwan-bbbb2222") {
		t.Errorf("expected orphan reap of sdwan-bbbb2222, got:\n%s", calls)
	}
	if strings.Contains(calls, "link delete sdwan-aaaa1111") {
		t.Errorf("expected NO delete of desired VRF, got:\n%s", calls)
	}
}

func TestVRFApplier_LeavesNonSdwanVRFsAlone(t *testing.T) {
	binPath, logPath, statePath := newRecorderIp(t)
	writeVRFState(t, statePath, map[string]int{
		"sdwan-aaaa1111": 100,
		"customer-vrf":   400, // operator-installed; not our prefix
	})
	a := &ShellVRFApplier{IpBin: binPath}

	desired := []DesiredVRF{
		{Name: "sdwan-aaaa1111", TableID: 100},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := strings.Join(readCalls(t, logPath), "\n")
	if strings.Contains(calls, "link delete customer-vrf") {
		t.Errorf("must NOT touch non-sdwan VRFs, got:\n%s", calls)
	}
}

func TestVRFApplier_InstallsSourceRules(t *testing.T) {
	binPath, logPath, _ := newRecorderIp(t)
	a := &ShellVRFApplier{IpBin: binPath}

	desired := []DesiredVRF{
		{Name: "sdwan-aaaa1111", TableID: 100,
			SourceAddrs: []string{"fd00:abcd::1", "10.20.30.5"}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := strings.Join(readCalls(t, logPath), "\n")
	wantV6 := "-6 rule add from fd00:abcd::1 table 100"
	wantV4 := "-4 rule add from 10.20.30.5 table 100"
	if !strings.Contains(calls, wantV6) {
		t.Errorf("expected %q, got:\n%s", wantV6, calls)
	}
	if !strings.Contains(calls, wantV4) {
		t.Errorf("expected %q, got:\n%s", wantV4, calls)
	}
}

// ----------------------------------------------------------------------
// parseVRFLinkShow — exercised separately from the applier so the JSON
// parsing logic is covered without invoking the shim.
// ----------------------------------------------------------------------

func TestParseVRFLinkShow_Empty(t *testing.T) {
	got, err := parseVRFLinkShow("")
	if err != nil {
		t.Fatalf("parse empty: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty map, got %v", got)
	}
}

func TestParseVRFLinkShow_SingleVRF(t *testing.T) {
	in := `[{"ifname":"sdwan-abc12345","linkinfo":{"info_kind":"vrf","info_data":{"table":100}}}]`
	got, err := parseVRFLinkShow(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got["sdwan-abc12345"] != 100 {
		t.Errorf("expected sdwan-abc12345=100, got %v", got)
	}
}

func TestParseVRFLinkShow_MultipleVRFs(t *testing.T) {
	in := `[
		{"ifname":"sdwan-aaaa1111","linkinfo":{"info_kind":"vrf","info_data":{"table":100}}},
		{"ifname":"sdwan-bbbb2222","linkinfo":{"info_kind":"vrf","info_data":{"table":101}}},
		{"ifname":"customer-vrf","linkinfo":{"info_kind":"vrf","info_data":{"table":400}}}
	]`
	got, err := parseVRFLinkShow(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got["sdwan-aaaa1111"] != 100 || got["sdwan-bbbb2222"] != 101 || got["customer-vrf"] != 400 {
		t.Errorf("unexpected parse result: %v", got)
	}
}

func TestExtractTableValue(t *testing.T) {
	cases := []struct {
		in    string
		want  int
		found bool
	}{
		{`"table":100,`, 100, true},
		{`"table":65535}`, 65535, true},
		{`"table": 200`, 200, true},
		{``, 0, false},
		{`"other":300`, 0, false},
	}
	for _, c := range cases {
		got, ok := extractTableValue(c.in)
		if got != c.want || ok != c.found {
			t.Errorf("extractTableValue(%q) = (%d,%v), want (%d,%v)", c.in, got, ok, c.want, c.found)
		}
	}
}
