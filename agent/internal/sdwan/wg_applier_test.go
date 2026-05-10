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

func newWgRecorderShims(t *testing.T) (ipBin, wgBin, ipLog, wgLog string) {
	t.Helper()

	dir := t.TempDir()
	ipBin = filepath.Join(dir, "ip")
	wgBin = filepath.Join(dir, "wg")
	ipLog = filepath.Join(dir, "ip-calls")
	wgLog = filepath.Join(dir, "wg-calls")
	state := filepath.Join(dir, "state")

	for _, p := range []string{ipLog, wgLog, state} {
		if err := os.WriteFile(p, []byte(""), 0o644); err != nil {
			t.Fatalf("seed %s: %v", p, err)
		}
	}

	ipScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "$@" >> %q
case "$*" in
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
`, ipLog, state, state)

	wgScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "$@" >> %q
exit 0
`, wgLog)

	if err := os.WriteFile(ipBin, []byte(ipScript), 0o755); err != nil {
		t.Fatalf("write ip shim: %v", err)
	}
	if err := os.WriteFile(wgBin, []byte(wgScript), 0o755); err != nil {
		t.Fatalf("write wg shim: %v", err)
	}
	return
}

func TestWgApplier_BindsIfaceToVRFOnCreate(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}

	ipBin, wgBin, ipLog, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-aaaa11",
		Address:    "fd00:abcd::1/128",
		ListenPort: 51820,
		MTU:        1420,
		VrfName:    "sdwan-aaaa11",
	}
	if err := a.ApplyInterface(context.Background(), cfg, nil, "fakeprivkey="); err != nil {
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
	ipBin, wgBin, ipLog, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-bbbb22",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		// VrfName empty — static-routing networks may not have a VRF
		// allocated; the applier must not attempt the bind.
	}
	if err := a.ApplyInterface(context.Background(), cfg, nil, "fakeprivkey="); err != nil {
		t.Fatalf("apply: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	if strings.Contains(string(raw), "link set wg-sdwan-bbbb22 master") {
		t.Errorf("must not bind when VrfName empty, got:\n%s", string(raw))
	}
}

func TestWgApplier_BindIsIdempotent_RebindEveryReconcile(t *testing.T) {
	// The applier issues `ip link set X master Y` on every reconcile to
	// self-correct from a misconfigured master. Verify two consecutive
	// applies both record the bind.
	ipBin, wgBin, ipLog, _ := newWgRecorderShims(t)
	a := &ShellApplier{IpPath: ipBin, WgPath: wgBin}

	cfg := InterfaceConf{
		Name:       "wg-sdwan-cccc33",
		Address:    "fd00::1/128",
		ListenPort: 51820,
		MTU:        1420,
		VrfName:    "sdwan-cccc33",
	}
	if err := a.ApplyInterface(context.Background(), cfg, nil, "fakeprivkey="); err != nil {
		t.Fatalf("apply 1: %v", err)
	}
	if err := a.ApplyInterface(context.Background(), cfg, nil, "fakeprivkey="); err != nil {
		t.Fatalf("apply 2: %v", err)
	}

	raw, _ := os.ReadFile(ipLog)
	occurrences := strings.Count(string(raw), "link set wg-sdwan-cccc33 master sdwan-cccc33")
	if occurrences < 2 {
		t.Errorf("expected ≥2 bind calls across two reconciles, got %d in:\n%s", occurrences, string(raw))
	}
}
