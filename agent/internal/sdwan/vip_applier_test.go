// vip_applier_test.go — unit tests for the Phase N1a per-VRF dummy
// VIP applier. Same recorder-shim strategy as vrf_applier_test.

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

// newVipRecorderIp installs a fake `ip` binary that:
//   - logs all argv to <tempdir>/ip-calls
//   - returns canned stdout for `link show type dummy` based on
//     <tempdir>/dummies (one ifname per line)
//   - returns canned stdout for `addr show dev <name>` based on
//     <tempdir>/addrs/<name> (one CIDR per line)
//   - returns 0 for everything else (link add/set, addr add/del, …)
func newVipRecorderIp(t *testing.T) (binPath, logPath, dummiesPath, addrsDir string) {
	t.Helper()

	dir := t.TempDir()
	binPath = filepath.Join(dir, "ip")
	logPath = filepath.Join(dir, "ip-calls")
	dummiesPath = filepath.Join(dir, "dummies")
	addrsDir = filepath.Join(dir, "addrs")

	if err := os.WriteFile(logPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed log: %v", err)
	}
	if err := os.WriteFile(dummiesPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed dummies: %v", err)
	}
	if err := os.MkdirAll(addrsDir, 0o755); err != nil {
		t.Fatalf("seed addrs: %v", err)
	}

	script := fmt.Sprintf(`#!/usr/bin/env bash
echo "$@" >> %q
args="$*"
case "$args" in
    "-o link show type dummy")
        idx=1
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            echo "$idx: $name: <BROADCAST,NOARP> mtu 1500 qdisc noqueue state UP"
            idx=$((idx+1))
        done < %q
        ;;
    "-o addr show dev "*)
        ifname="${args##* }"
        f="%s/$ifname"
        if [ -f "$f" ]; then
            idx=1
            while IFS= read -r cidr; do
                [ -z "$cidr" ] && continue
                case "$cidr" in
                    *:*) family="inet6" ;;
                    *)   family="inet" ;;
                esac
                echo "$idx: $ifname    $family $cidr scope global $ifname"
                idx=$((idx+1))
            done < "$f"
        fi
        ;;
    "link show "*)
        target="${args##* }"
        if grep -q "^$target$" %q 2>/dev/null; then
            exit 0
        fi
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
`, logPath, dummiesPath, addrsDir, dummiesPath)

	if err := os.WriteFile(binPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write shim: %v", err)
	}
	return
}

func writeDummies(t *testing.T, dummiesPath string, names []string) {
	t.Helper()
	sort.Strings(names)
	body := strings.Join(names, "\n") + "\n"
	if err := os.WriteFile(dummiesPath, []byte(body), 0o644); err != nil {
		t.Fatalf("write dummies: %v", err)
	}
}

func writeAddrs(t *testing.T, addrsDir, ifname string, cidrs []string) {
	t.Helper()
	// Ensure a trailing newline so bash's `read -r` picks up the last
	// entry (POSIX `read` returns nonzero for the final line if it
	// lacks a newline, even when it sets the variable).
	body := strings.Join(cidrs, "\n") + "\n"
	if err := os.WriteFile(filepath.Join(addrsDir, ifname), []byte(body), 0o644); err != nil {
		t.Fatalf("write addrs: %v", err)
	}
}

func vipReadCalls(t *testing.T, logPath string) string {
	t.Helper()
	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read calls: %v", err)
	}
	return strings.TrimSpace(string(raw))
}

func TestVipApplier_CreatesPerVRFDummyAndAddsAddress(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	binPath, logPath, _, _ := newVipRecorderIp(t)
	a := &ShellVipApplier{IpBin: binPath}

	desired := []VipConf{
		{VipID: "v1", Cidr: "fd00:abcd::1/128", VrfName: "sdwan-aaaa11"},
	}
	if err := a.ApplyVips(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := vipReadCalls(t, logPath)
	wantCreate := "link add d-sdwan-aaaa11 type dummy"
	if !strings.Contains(calls, wantCreate) {
		t.Errorf("expected %q in calls, got:\n%s", wantCreate, calls)
	}
	wantBind := "link set d-sdwan-aaaa11 master sdwan-aaaa11"
	if !strings.Contains(calls, wantBind) {
		t.Errorf("expected %q in calls, got:\n%s", wantBind, calls)
	}
	wantUp := "link set d-sdwan-aaaa11 up"
	if !strings.Contains(calls, wantUp) {
		t.Errorf("expected %q in calls, got:\n%s", wantUp, calls)
	}
	wantAddr := "addr add fd00:abcd::1/128 dev d-sdwan-aaaa11"
	if !strings.Contains(calls, wantAddr) {
		t.Errorf("expected %q in calls, got:\n%s", wantAddr, calls)
	}
}

func TestVipApplier_NeverTouchesGlobalLoopback(t *testing.T) {
	binPath, logPath, _, _ := newVipRecorderIp(t)
	a := &ShellVipApplier{IpBin: binPath}

	desired := []VipConf{
		{VipID: "v1", Cidr: "fd00:abcd::1/128", VrfName: "sdwan-aaaa11"},
	}
	if err := a.ApplyVips(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := vipReadCalls(t, logPath)
	// The pre-N1a code wrote `addr add ... dev lo`; that path is gone.
	if strings.Contains(calls, "dev lo") {
		t.Errorf("Phase N1a forbids writing to the global loopback. Calls:\n%s", calls)
	}
}

func TestVipApplier_SkipsEntriesWithoutVrfName(t *testing.T) {
	binPath, logPath, _, _ := newVipRecorderIp(t)
	a := &ShellVipApplier{IpBin: binPath}

	desired := []VipConf{
		{VipID: "no-vrf", Cidr: "fd00::1/128", VrfName: ""}, // skipped
		{VipID: "v1", Cidr: "fd00:abcd::1/128", VrfName: "sdwan-aaaa11"},
	}
	if err := a.ApplyVips(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := vipReadCalls(t, logPath)
	if strings.Contains(calls, "fd00::1/128") {
		t.Errorf("entry without VrfName should be skipped, got call for fd00::1/128:\n%s", calls)
	}
	if !strings.Contains(calls, "fd00:abcd::1/128") {
		t.Errorf("expected the VRF-bound entry to be installed, got:\n%s", calls)
	}
}

func TestVipApplier_RemovesOrphanAddresses(t *testing.T) {
	binPath, logPath, dummiesPath, addrsDir := newVipRecorderIp(t)

	// Pre-existing dummy with two addresses; only one is desired.
	writeDummies(t, dummiesPath, []string{"d-sdwan-aaaa11"})
	writeAddrs(t, addrsDir, "d-sdwan-aaaa11", []string{
		"fd00:abcd::1/128",
		"fd00:abcd::2/128",
	})

	a := &ShellVipApplier{IpBin: binPath}
	desired := []VipConf{
		{VipID: "keeper", Cidr: "fd00:abcd::1/128", VrfName: "sdwan-aaaa11"},
	}
	if err := a.ApplyVips(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := vipReadCalls(t, logPath)
	wantDel := "addr del fd00:abcd::2/128 dev d-sdwan-aaaa11"
	if !strings.Contains(calls, wantDel) {
		t.Errorf("expected orphan address removal %q, got:\n%s", wantDel, calls)
	}
	if strings.Contains(calls, "addr del fd00:abcd::1/128") {
		t.Errorf("must not delete desired address, got:\n%s", calls)
	}
}

func TestVipApplier_ReapsDummyWhoseVRFIsGone(t *testing.T) {
	binPath, logPath, dummiesPath, _ := newVipRecorderIp(t)
	writeDummies(t, dummiesPath, []string{
		"d-sdwan-aaaa11", // desired
		"d-sdwan-bbbb22", // orphan
	})
	a := &ShellVipApplier{IpBin: binPath}

	desired := []VipConf{
		{VipID: "v1", Cidr: "fd00:abcd::1/128", VrfName: "sdwan-aaaa11"},
	}
	if err := a.ApplyVips(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := vipReadCalls(t, logPath)
	if !strings.Contains(calls, "link delete d-sdwan-bbbb22") {
		t.Errorf("expected orphan dummy reap, got:\n%s", calls)
	}
	if strings.Contains(calls, "link delete d-sdwan-aaaa11") {
		t.Errorf("must not delete desired dummy, got:\n%s", calls)
	}
}

func TestVipApplier_IsIdempotent(t *testing.T) {
	binPath, logPath, dummiesPath, addrsDir := newVipRecorderIp(t)
	writeDummies(t, dummiesPath, []string{"d-sdwan-aaaa11"})
	writeAddrs(t, addrsDir, "d-sdwan-aaaa11", []string{"fd00:abcd::1/128"})
	a := &ShellVipApplier{IpBin: binPath}

	desired := []VipConf{
		{VipID: "v1", Cidr: "fd00:abcd::1/128", VrfName: "sdwan-aaaa11"},
	}
	if err := a.ApplyVips(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := vipReadCalls(t, logPath)
	// Address is already there → no add call.
	if strings.Contains(calls, "addr add fd00:abcd::1/128") {
		t.Errorf("expected NO addr add for existing address, got:\n%s", calls)
	}
	// Dummy is already there → no link add for it.
	if strings.Contains(calls, "link add d-sdwan-aaaa11 type dummy") {
		t.Errorf("expected NO link add for existing dummy, got:\n%s", calls)
	}
}

func TestVipApplier_GroupsMultipleVIPsByVRF(t *testing.T) {
	binPath, logPath, _, _ := newVipRecorderIp(t)
	a := &ShellVipApplier{IpBin: binPath}

	desired := []VipConf{
		{VipID: "a1", Cidr: "fd00:a::1/128", VrfName: "sdwan-aaaa11"},
		{VipID: "a2", Cidr: "fd00:a::2/128", VrfName: "sdwan-aaaa11"},
		{VipID: "b1", Cidr: "fd00:b::1/128", VrfName: "sdwan-bbbb22"},
	}
	if err := a.ApplyVips(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := vipReadCalls(t, logPath)
	for _, want := range []string{
		"link add d-sdwan-aaaa11 type dummy",
		"link add d-sdwan-bbbb22 type dummy",
		"addr add fd00:a::1/128 dev d-sdwan-aaaa11",
		"addr add fd00:a::2/128 dev d-sdwan-aaaa11",
		"addr add fd00:b::1/128 dev d-sdwan-bbbb22",
	} {
		if !strings.Contains(calls, want) {
			t.Errorf("missing %q in calls:\n%s", want, calls)
		}
	}
}

// ----------------------------------------------------------------------
// dummyNameForVRF / vrfNameFromDummy round-trip.
// ----------------------------------------------------------------------

func TestVipApplier_DummyVRFNameRoundTrip(t *testing.T) {
	cases := []string{"sdwan-abc12345", "sdwan-zzzzzzzz"}
	for _, vrfName := range cases {
		got := vrfNameFromDummy(dummyNameForVRF(vrfName))
		if got != vrfName {
			t.Errorf("round-trip %q: got %q", vrfName, got)
		}
	}
	// Non-conforming names return empty.
	if got := vrfNameFromDummy("eth0"); got != "" {
		t.Errorf("vrfNameFromDummy(eth0) should return empty, got %q", got)
	}
}
