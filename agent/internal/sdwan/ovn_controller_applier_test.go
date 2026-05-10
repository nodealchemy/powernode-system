// ovn_controller_applier_test.go — unit tests for the Phase O3
// ovn-controller lifecycle + OVS encap-config applier.
//
// Strategy: install TWO fake binaries (`systemctl` and `ovs-vsctl`)
// in tempdir using the recorder-shim pattern from
// ovs_bridge_applier_test. Both shims append to a shared call log
// prefixed with the binary name so tests can assert ordering across
// binaries (e.g. ovs-vsctl set commands must run BEFORE
// `systemctl start ovn-controller`).
//
// The systemctl shim emits canned `is-active` output: stdout reads
// `<tempdir>/active` (the literal string "active" or "inactive") so
// tests can flip the daemon state between Apply calls. The ovs-vsctl
// shim is a no-op for `set` and any other call (the applier doesn't
// parse ovs-vsctl output for the encap-config path).
//
// Every other invocation exits 0 so the applier sees a successful
// process for each shell-out — tests inspect the call log to verify
// the right commands ran in the right order. No root, no OVS
// installed, no systemd.

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

// newOvnRecorderBins installs fake `systemctl` AND `ovs-vsctl`
// binaries in tempdir. Both write to the same call log with a prefix
// so tests can distinguish (and assert on) which binary was invoked.
//
// Returns:
//   - systemctlBin — absolute path to the fake systemctl binary.
//   - ovsBin       — absolute path to the fake ovs-vsctl binary.
//   - logPath      — shared call log; each line is "<bin>: <argv>".
//   - activePath   — single-line file the systemctl shim reads to
//     decide what `is-active` should print. Tests overwrite to switch
//     the daemon's apparent state between calls.
func newOvnRecorderBins(t *testing.T) (systemctlBin, ovsBin, logPath, activePath string) {
	t.Helper()

	dir := t.TempDir()
	systemctlBin = filepath.Join(dir, "systemctl")
	ovsBin = filepath.Join(dir, "ovs-vsctl")
	logPath = filepath.Join(dir, "calls")
	activePath = filepath.Join(dir, "active")

	if err := os.WriteFile(logPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed log: %v", err)
	}
	// Default to "inactive" so a fresh fixture mimics a host where
	// ovn-controller has not been started yet.
	if err := os.WriteFile(activePath, []byte("inactive\n"), 0o644); err != nil {
		t.Fatalf("seed active: %v", err)
	}

	// systemctl shim — handles `is-active <unit>` (echo file contents,
	// exit 0 for "active" / 3 for anything else, mirroring real
	// systemctl), and any other invocation (silent exit 0).
	systemctlScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "systemctl: $*" >> %q
args="$*"
case "$args" in
    "is-active "*)
        state=$(cat %q | tr -d '[:space:]')
        echo "$state"
        if [ "$state" = "active" ]; then
            exit 0
        else
            # Real systemctl exits 3 for inactive/failed; mirror that
            # so the applier's tolerance of ExitError gets exercised.
            exit 3
        fi
        ;;
    *)
        exit 0
        ;;
esac
`, logPath, activePath)

	// ovs-vsctl shim — silent success for everything (the encap-config
	// path doesn't read any ovs-vsctl output).
	ovsScript := fmt.Sprintf(`#!/usr/bin/env bash
echo "ovs-vsctl: $*" >> %q
exit 0
`, logPath)

	if err := os.WriteFile(systemctlBin, []byte(systemctlScript), 0o755); err != nil {
		t.Fatalf("write systemctl shim: %v", err)
	}
	if err := os.WriteFile(ovsBin, []byte(ovsScript), 0o755); err != nil {
		t.Fatalf("write ovs shim: %v", err)
	}
	return
}

func setOvnUnitActive(t *testing.T, activePath string, active bool) {
	t.Helper()
	state := "inactive\n"
	if active {
		state = "active\n"
	}
	if err := os.WriteFile(activePath, []byte(state), 0o644); err != nil {
		t.Fatalf("set active: %v", err)
	}
}

func ovnReadCalls(t *testing.T, logPath string) string {
	t.Helper()
	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read calls: %v", err)
	}
	return strings.TrimSpace(string(raw))
}

func ovnTruncateCalls(t *testing.T, logPath string) {
	t.Helper()
	if err := os.WriteFile(logPath, []byte(""), 0o644); err != nil {
		t.Fatalf("truncate calls: %v", err)
	}
}

// ----------------------------------------------------------------------
// Apply contract tests
// ----------------------------------------------------------------------

// 1) Nil desired with ovn-controller stopped → no shell calls beyond
// the optional is-active probe; specifically NO `systemctl stop`. The
// disabled-path early-returns once it sees the unit is already
// inactive, so the start/stop log MUST be empty.
func TestOvnControllerApplier_NilDesiredWithUnitStoppedDoesNothing(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, false)
	a := &ShellOvnControllerApplier{SystemctlBin: systemctlBin, OvsVsctlBin: ovsBin}

	if err := a.Apply(context.Background(), nil); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovnReadCalls(t, logPath)
	// is-active is allowed (the applier needs it to know whether to stop).
	// stop and ovs-vsctl set must NOT appear.
	if strings.Contains(calls, "systemctl: stop ovn-controller") {
		t.Errorf("expected NO `systemctl stop` for already-stopped unit, got:\n%s", calls)
	}
	if strings.Contains(calls, "ovs-vsctl:") {
		t.Errorf("expected NO ovs-vsctl calls on disabled path, got:\n%s", calls)
	}
}

// 2) Nil desired with ovn-controller active → stop call issued.
func TestOvnControllerApplier_NilDesiredWithUnitActiveStopsIt(t *testing.T) {
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, true)
	a := &ShellOvnControllerApplier{SystemctlBin: systemctlBin, OvsVsctlBin: ovsBin}

	if err := a.Apply(context.Background(), nil); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovnReadCalls(t, logPath)
	wantStop := "systemctl: stop ovn-controller"
	if !strings.Contains(calls, wantStop) {
		t.Errorf("expected %q in calls, got:\n%s", wantStop, calls)
	}
	// Disabled path must not touch OVS.
	if strings.Contains(calls, "ovs-vsctl:") {
		t.Errorf("expected NO ovs-vsctl calls on disabled path, got:\n%s", calls)
	}
}

// 3) Set desired with ovn-controller stopped → all four ovs-vsctl set
// calls + start call.
func TestOvnControllerApplier_DesiredWithUnitStoppedConfiguresAndStarts(t *testing.T) {
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, false)
	a := &ShellOvnControllerApplier{SystemctlBin: systemctlBin, OvsVsctlBin: ovsBin}

	desired := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
		EncapType:    "geneve",
		ChassisName:  "chassis-abc",
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovnReadCalls(t, logPath)

	// All four external_ids sets must be present.
	wantSets := []string{
		`ovs-vsctl: set Open_vSwitch . external_ids:ovn-encap-type="geneve"`,
		`ovs-vsctl: set Open_vSwitch . external_ids:ovn-encap-ip="fd00::1"`,
		`ovs-vsctl: set Open_vSwitch . external_ids:ovn-remote="tcp:10.0.0.1:6642"`,
		`ovs-vsctl: set Open_vSwitch . external_ids:system-id="chassis-abc"`,
	}
	for _, want := range wantSets {
		if !strings.Contains(calls, want) {
			t.Errorf("expected %q in calls, got:\n%s", want, calls)
		}
	}
	// And the start call.
	if !strings.Contains(calls, "systemctl: start ovn-controller") {
		t.Errorf("expected `systemctl start ovn-controller`, got:\n%s", calls)
	}
}

// 4) Set desired with ovn-controller active → ovs-vsctl set calls
// MUST appear but `systemctl start` MUST NOT (steady-state apply
// shouldn't bounce the daemon).
func TestOvnControllerApplier_DesiredWithUnitActiveDoesNotRestart(t *testing.T) {
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, true)
	a := &ShellOvnControllerApplier{SystemctlBin: systemctlBin, OvsVsctlBin: ovsBin}

	desired := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
		EncapType:    "geneve",
		ChassisName:  "chassis-abc",
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovnReadCalls(t, logPath)
	if !strings.Contains(calls, "ovs-vsctl: set Open_vSwitch . external_ids:ovn-remote") {
		t.Errorf("expected ovs-vsctl set calls even when unit active, got:\n%s", calls)
	}
	if strings.Contains(calls, "systemctl: start ovn-controller") {
		t.Errorf("expected NO `systemctl start` when unit already active, got:\n%s", calls)
	}
	if strings.Contains(calls, "systemctl: stop ovn-controller") {
		t.Errorf("expected NO `systemctl stop` on enabled path, got:\n%s", calls)
	}
}

// 5) EncapType defaults to "geneve" when blank.
func TestOvnControllerApplier_DefaultsEncapTypeToGeneve(t *testing.T) {
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, false)
	a := &ShellOvnControllerApplier{SystemctlBin: systemctlBin, OvsVsctlBin: ovsBin}

	desired := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
		// EncapType omitted on purpose
		ChassisName: "chassis-abc",
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovnReadCalls(t, logPath)
	want := `ovs-vsctl: set Open_vSwitch . external_ids:ovn-encap-type="geneve"`
	if !strings.Contains(calls, want) {
		t.Errorf("expected default encap-type=geneve, got:\n%s", calls)
	}
}

// 6) ChassisName defaults to os.Hostname when blank.
func TestOvnControllerApplier_DefaultsChassisNameToHostname(t *testing.T) {
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, false)
	a := &ShellOvnControllerApplier{
		SystemctlBin: systemctlBin,
		OvsVsctlBin:  ovsBin,
		hostnameFn:   func() (string, error) { return "test-host-42", nil },
	}

	desired := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
		// ChassisName omitted; should fall back to hostname.
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovnReadCalls(t, logPath)
	want := `ovs-vsctl: set Open_vSwitch . external_ids:system-id="test-host-42"`
	if !strings.Contains(calls, want) {
		t.Errorf("expected system-id from hostname, got:\n%s", calls)
	}
}

// 7) Idempotent — second apply with the same desired and active unit
// produces NO start (it's already active) and NO stop.
func TestOvnControllerApplier_IsIdempotent(t *testing.T) {
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, false)
	a := &ShellOvnControllerApplier{SystemctlBin: systemctlBin, OvsVsctlBin: ovsBin}

	desired := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
		EncapType:    "geneve",
		ChassisName:  "chassis-abc",
	}

	// First apply — should issue start.
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("first apply: %v", err)
	}
	// Simulate the daemon coming up (real systemd would do this).
	setOvnUnitActive(t, activePath, true)
	// Reset call log so we only inspect the second-apply behavior.
	ovnTruncateCalls(t, logPath)

	// Second apply — same desired, unit now active.
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("second apply: %v", err)
	}

	calls := ovnReadCalls(t, logPath)
	if strings.Contains(calls, "systemctl: start ovn-controller") {
		t.Errorf("expected NO start on idempotent reapply, got:\n%s", calls)
	}
	if strings.Contains(calls, "systemctl: stop ovn-controller") {
		t.Errorf("expected NO stop on idempotent reapply, got:\n%s", calls)
	}
}

// 8) Returns clear error when ovs-vsctl is missing on the heavyweight
// path. The platform's network_profile check should prevent this in
// production, but the agent must surface a clear message rather than
// crash.
func TestOvnControllerApplier_ReturnsErrorWhenOvsVsctlMissing(t *testing.T) {
	a := &ShellOvnControllerApplier{
		SystemctlBin: "/usr/bin/true", // arbitrary; we never reach systemctl
		OvsVsctlBin:  "/nonexistent/path/to/ovs-vsctl",
	}

	desired := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
	}
	err := a.Apply(context.Background(), desired)
	if err == nil {
		t.Fatalf("expected error when ovs-vsctl is missing, got nil")
	}
	if !strings.Contains(err.Error(), "ovs-vsctl") {
		t.Errorf("expected error to mention ovs-vsctl, got: %v", err)
	}
}

// 9) Returns clear error when systemctl is missing on the heavyweight
// path.
func TestOvnControllerApplier_ReturnsErrorWhenSystemctlMissing(t *testing.T) {
	systemctlBin, ovsBin, _, _ := newOvnRecorderBins(t)
	_ = systemctlBin // we override it intentionally
	a := &ShellOvnControllerApplier{
		SystemctlBin: "/nonexistent/path/to/systemctl",
		OvsVsctlBin:  ovsBin,
	}

	desired := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
	}
	err := a.Apply(context.Background(), desired)
	if err == nil {
		t.Fatalf("expected error when systemctl is missing, got nil")
	}
	if !strings.Contains(err.Error(), "systemctl") {
		t.Errorf("expected error to mention systemctl, got: %v", err)
	}
}

// 10) Empty SbDbEndpoint or EncapIp in non-nil desired returns a
// validation error WITHOUT shelling out (so the bad-config path can't
// half-write OVS state).
func TestOvnControllerApplier_ValidationErrors(t *testing.T) {
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, false)

	cases := []struct {
		name    string
		desired *DesiredOvnControl
		wantSub string
	}{
		{
			name:    "empty SbDbEndpoint",
			desired: &DesiredOvnControl{SbDbEndpoint: "", EncapIp: "fd00::1"},
			wantSub: "SbDbEndpoint",
		},
		{
			name:    "whitespace SbDbEndpoint",
			desired: &DesiredOvnControl{SbDbEndpoint: "   ", EncapIp: "fd00::1"},
			wantSub: "SbDbEndpoint",
		},
		{
			name:    "empty EncapIp",
			desired: &DesiredOvnControl{SbDbEndpoint: "tcp:10.0.0.1:6642", EncapIp: ""},
			wantSub: "EncapIp",
		},
		{
			name:    "whitespace EncapIp",
			desired: &DesiredOvnControl{SbDbEndpoint: "tcp:10.0.0.1:6642", EncapIp: "\t"},
			wantSub: "EncapIp",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ovnTruncateCalls(t, logPath)
			a := &ShellOvnControllerApplier{SystemctlBin: systemctlBin, OvsVsctlBin: ovsBin}
			err := a.Apply(context.Background(), tc.desired)
			if err == nil {
				t.Fatalf("expected validation error for %s, got nil", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Errorf("expected error to mention %q, got: %v", tc.wantSub, err)
			}
			calls := ovnReadCalls(t, logPath)
			if strings.Contains(calls, "ovs-vsctl:") {
				t.Errorf("validation must short-circuit before ovs-vsctl shell-out, got:\n%s", calls)
			}
			if strings.Contains(calls, "systemctl: start") || strings.Contains(calls, "systemctl: stop") {
				t.Errorf("validation must short-circuit before systemctl, got:\n%s", calls)
			}
		})
	}
}

// 11) Hostname-fallback test — explicit confirmation that an empty
// ChassisName triggers the os.Hostname swap-in. Distinct from test 6
// because here we use a different sentinel hostname AND explicitly
// confirm the call to the override fired.
func TestOvnControllerApplier_HostnameFallback(t *testing.T) {
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, false)

	called := 0
	a := &ShellOvnControllerApplier{
		SystemctlBin: systemctlBin,
		OvsVsctlBin:  ovsBin,
		hostnameFn: func() (string, error) {
			called++
			return "node-from-hostname", nil
		},
	}

	desired := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
		ChassisName:  "", // force fallback
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}
	if called == 0 {
		t.Fatalf("expected hostname fallback to fire, called=%d", called)
	}

	calls := ovnReadCalls(t, logPath)
	want := `external_ids:system-id="node-from-hostname"`
	if !strings.Contains(calls, want) {
		t.Errorf("expected hostname-derived system-id, got:\n%s", calls)
	}

	// Sanity: an explicit ChassisName MUST take precedence over the
	// hostname fallback (no extra call to hostnameFn).
	ovnTruncateCalls(t, logPath)
	called = 0
	desired2 := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
		ChassisName:  "explicit-name",
	}
	if err := a.Apply(context.Background(), desired2); err != nil {
		t.Fatalf("apply explicit: %v", err)
	}
	if called != 0 {
		t.Errorf("expected NO hostname fallback when ChassisName set, called=%d", called)
	}
	calls = ovnReadCalls(t, logPath)
	if !strings.Contains(calls, `external_ids:system-id="explicit-name"`) {
		t.Errorf("expected explicit ChassisName to win, got:\n%s", calls)
	}
}

// ----------------------------------------------------------------------
// Ordering test — OVS config must land BEFORE the systemctl start so
// ovn-controller reads a complete external_ids map at startup. (If we
// started the daemon first, it would briefly run with stale or empty
// encap config until the next ovsdb-watch tick.)
// ----------------------------------------------------------------------

func TestOvnControllerApplier_ApplyOrderingOvsConfigBeforeStart(t *testing.T) {
	systemctlBin, ovsBin, logPath, activePath := newOvnRecorderBins(t)
	setOvnUnitActive(t, activePath, false)
	a := &ShellOvnControllerApplier{SystemctlBin: systemctlBin, OvsVsctlBin: ovsBin}

	desired := &DesiredOvnControl{
		SbDbEndpoint: "tcp:10.0.0.1:6642",
		EncapIp:      "fd00::1",
		ChassisName:  "chassis-abc",
	}
	if err := a.Apply(context.Background(), desired); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := ovnReadCalls(t, logPath)
	// Pick the LAST ovs-vsctl set (system-id is issued fourth) and the
	// systemctl start; the start must come after.
	lastSetIdx := strings.LastIndex(calls, `ovs-vsctl: set Open_vSwitch . external_ids:`)
	startIdx := strings.Index(calls, "systemctl: start ovn-controller")
	if lastSetIdx < 0 {
		t.Fatalf("missing ovs-vsctl set call:\n%s", calls)
	}
	if startIdx < 0 {
		t.Fatalf("missing systemctl start call:\n%s", calls)
	}
	if lastSetIdx > startIdx {
		t.Errorf("expected all ovs-vsctl sets before systemctl start; got lastSet@%d, start@%d:\n%s",
			lastSetIdx, startIdx, calls)
	}
}
