// ovs_bridge_applier_ipfix_test.go — Phase O5 tests for the
// OvsBridgeApplier's IPFIX reconcile path. Uses the same recorder-shim
// pattern as the rest of the package: a fake `ovs-vsctl` records its
// argv to a shared call log, the test asserts on the captured commands.

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

func newOvsIpfixRecorderShim(t *testing.T) (ovsBin, ipBin, callLog string) {
	t.Helper()

	dir := t.TempDir()
	ovsBin = filepath.Join(dir, "ovs-vsctl")
	ipBin = filepath.Join(dir, "ip")
	callLog = filepath.Join(dir, "calls")

	if err := os.WriteFile(callLog, []byte(""), 0o644); err != nil {
		t.Fatalf("seed call log: %v", err)
	}

	// ovs-vsctl shim: log its argv, default-zero exit. For `list-br`
	// emit one line so the applier's create-then-update path runs.
	ovsScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "ovs-vsctl: $*" >> %q
case "$1" in
    list-br)
        # No bridges initially — Apply will create them.
        ;;
esac
exit 0
`, callLog)

	ipScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "ip: $*" >> %q
case "$*" in
    *"-j addr show"*)
        # Empty address list (no orphan addrs to reconcile).
        ;;
esac
exit 0
`, callLog)

	if err := os.WriteFile(ovsBin, []byte(ovsScript), 0o755); err != nil {
		t.Fatalf("write ovs shim: %v", err)
	}
	if err := os.WriteFile(ipBin, []byte(ipScript), 0o755); err != nil {
		t.Fatalf("write ip shim: %v", err)
	}
	return
}

func readOvsIpfixCalls(t *testing.T, callLog string) string {
	t.Helper()
	raw, err := os.ReadFile(callLog)
	if err != nil {
		t.Fatalf("read call log: %v", err)
	}
	return string(raw)
}

func TestOvsBridgeApplier_IpfixSetWhenDesired(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ovsBin, ipBin, callLog := newOvsIpfixRecorderShim(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-1", Kind: "ovs", Ipfix: &DesiredIpfix{
			CollectorID: "test",
			Targets:     []string{"10.0.0.1:4739"},
			Sampling:    1,
		}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := readOvsIpfixCalls(t, callLog)

	// Look for the IPFIX-create + bridge-set transaction. ovs-vsctl
	// invokes look like: `ovs-vsctl: -- --id=@ipfix create IPFIX targets=["..."] sampling=1 -- set Bridge pwnbr-1 ipfix=@ipfix`
	if !strings.Contains(calls, `--id=@ipfix create IPFIX`) {
		t.Errorf("expected IPFIX create in calls, got:\n%s", calls)
	}
	if !strings.Contains(calls, `targets=["10.0.0.1:4739"]`) {
		t.Errorf("expected targets in IPFIX create, got:\n%s", calls)
	}
	if !strings.Contains(calls, "sampling=1") {
		t.Errorf("expected sampling=1 in IPFIX create, got:\n%s", calls)
	}
	if !strings.Contains(calls, "set Bridge pwnbr-1 ipfix=@ipfix") {
		t.Errorf("expected Bridge ipfix link in calls, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_IpfixClearedWhenNil(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	ovsBin, ipBin, callLog := newOvsIpfixRecorderShim(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-2", Kind: "ovs", Ipfix: nil},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := readOvsIpfixCalls(t, callLog)

	if !strings.Contains(calls, "clear Bridge pwnbr-2 ipfix") {
		t.Errorf("expected ipfix clear when desired.Ipfix is nil, got:\n%s", calls)
	}
	if strings.Contains(calls, "create IPFIX") {
		t.Errorf("nil Ipfix should not create an IPFIX row, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_IpfixIPv6TargetBracketed(t *testing.T) {
	// The platform's IpfixCollector#target_endpoint already brackets
	// IPv6 hosts. The applier just passes the string through, but we
	// verify it doesn't accidentally strip brackets in OVSDB literal
	// rendering.
	ovsBin, ipBin, callLog := newOvsIpfixRecorderShim(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-3", Kind: "ovs", Ipfix: &DesiredIpfix{
			Targets: []string{"[fd00::1]:4739"},
			Sampling: 16,
		}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := readOvsIpfixCalls(t, callLog)

	if !strings.Contains(calls, `targets=["[fd00::1]:4739"]`) {
		t.Errorf("expected bracketed IPv6 target in IPFIX create, got:\n%s", calls)
	}
	if !strings.Contains(calls, "sampling=16") {
		t.Errorf("expected sampling=16 in IPFIX create, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_IpfixWithEmptyTargetsActsAsClear(t *testing.T) {
	// Defensive — empty targets list should behave like nil Ipfix
	// (clear) rather than emit an OVSDB literal with no entries.
	ovsBin, ipBin, callLog := newOvsIpfixRecorderShim(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-4", Kind: "ovs", Ipfix: &DesiredIpfix{
			Targets: []string{},
		}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := readOvsIpfixCalls(t, callLog)

	if !strings.Contains(calls, "clear Bridge pwnbr-4 ipfix") {
		t.Errorf("expected ipfix clear for empty targets, got:\n%s", calls)
	}
	if strings.Contains(calls, "create IPFIX") {
		t.Errorf("empty targets should not create an IPFIX row, got:\n%s", calls)
	}
}

func TestOvsBridgeApplier_IpfixSkippedForLinuxKind(t *testing.T) {
	// The Kind filter at the top of Apply already drops linux entries
	// before reconcileIpfix runs. This test pins that contract from
	// the IPFIX angle: even with a populated Ipfix block, a linux-kind
	// entry produces no ovs-vsctl calls at all.
	ovsBin, ipBin, callLog := newOvsIpfixRecorderShim(t)
	a := &ShellOvsBridgeApplier{OvsVsctlBin: ovsBin, IpBin: ipBin}

	desired := []DesiredBridge{
		{Name: "pwnbr-5", Kind: "linux", Ipfix: &DesiredIpfix{
			Targets: []string{"10.0.0.1:4739"},
		}},
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := readOvsIpfixCalls(t, callLog)

	// Only `list-br` should fire — no per-bridge ovs-vsctl calls.
	if strings.Contains(calls, "create IPFIX") || strings.Contains(calls, "ipfix=@ipfix") {
		t.Errorf("linux-kind entry should be ignored by OvsBridgeApplier, got:\n%s", calls)
	}
}
