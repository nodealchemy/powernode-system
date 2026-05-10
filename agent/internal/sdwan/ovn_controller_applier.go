// ovn_controller_applier.go — Phase O3: agent-side lifecycle for the
// local `ovn-controller` daemon and the OVS-side encap config that
// tells it how to find the central OVN Southbound DB and which
// tunnel endpoint to advertise to the rest of the fleet.
//
// What this file owns:
//   * Start / stop the local `ovn-controller` systemd unit based on
//     whether the platform has stamped a non-nil DesiredOvnControl
//     for this host.
//   * Write four OVS local options into the local `Open_vSwitch`
//     row's `external_ids` map. ovn-controller reads these from OVSDB
//     at startup and on every change:
//       - `ovn-encap-type`  — tunnel type (geneve|stt|vxlan); we
//         default to geneve, matching OVN's recommended baseline.
//       - `ovn-encap-ip`    — the tunnel endpoint IP this host
//         advertises to the rest of the fleet. Stamped by the
//         platform as the host's SDWAN /128 so that OVN's Geneve
//         encapsulation rides over the SDWAN overlay.
//       - `ovn-remote`      — connection string for the OVN SB DB
//         (e.g., `tcp:10.0.0.1:6642`). The platform's
//         Sdwan::OvnDeployment row carries this.
//       - `system-id`       — unique chassis identifier this host
//         registers under in the SB DB's Chassis table. Defaults to
//         the host's hostname; the platform may override to use a
//         stable chassis ID derived from node UUID.
//
// What this file deliberately does NOT do:
//   * Doesn't manage the central daemons (`ovn-northd`, the OVN NB+SB
//     DBs). Those run on the platform side, not on individual nodes.
//   * Doesn't write any flows or logical-switch configuration —
//     ovn-controller programs OVS itself once the encap config is
//     correct and the SB DB is reachable.
//   * Doesn't manage the integration bridge (`br-int`). ovn-controller
//     creates and owns it; the agent leaves it alone.
//   * Doesn't enable / disable the systemd unit — that is part of
//     the disk image build, not per-tick reconcile. We start/stop the
//     existing unit based on per-host intent.
//
// Lightweight hosts get a nil DesiredOvnControl from the platform
// (their network_profile excludes OVN). The applier short-circuits
// in that case and never touches OVS or systemctl, so a host with
// neither `ovs-vsctl` nor an `ovn-controller` unit installed still
// sees a clean reconcile loop.
//
// Phase O3 of the OVS+OVN dual-profile networking roadmap.

package sdwan

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
)

// DesiredOvnControl is the per-host OVN-controller intent. Nil for
// lightweight hosts; populated for heavyweight hosts where the
// platform has an active Sdwan::OvnDeployment for the account.
//
// Stamped by the platform alongside DesiredConfig and threaded into
// the agent via DesiredConfig.OvnControl (added in Task #24, the
// integration step).
type DesiredOvnControl struct {
	// SbDbEndpoint is the connection string for the OVN Southbound
	// DB, e.g., "tcp:10.0.0.1:6642". Required; an empty value yields
	// a validation error from Apply.
	SbDbEndpoint string
	// EncapIp is the SDWAN /128 of THIS host (no prefix length). OVN
	// uses it as the local tunnel endpoint advertised in the SB DB's
	// Chassis row. Required; an empty value yields a validation error.
	EncapIp string
	// EncapType is the OVN tunnel type. Defaults to "geneve" when
	// blank. Geneve is OVN's recommended baseline; the field exists
	// so a future deployment can override (e.g., stt for an MTU-
	// constrained underlay).
	EncapType string
	// ChassisName is the unique identifier this host registers under
	// in the SB DB's Chassis table. Defaults to os.Hostname() when
	// blank. Stable across restarts; the platform can override to a
	// node-UUID-derived value if it wants chassis identity to be
	// independent of hostname changes.
	ChassisName string
}

// OvnControllerApplier is the strategy-pattern interface for applying
// DesiredOvnControl. ShellOvnControllerApplier is the production
// implementation; tests substitute a recorder shim by overriding the
// SystemctlBin / OvsVsctlBin paths.
type OvnControllerApplier interface {
	Apply(ctx context.Context, desired *DesiredOvnControl) error
}

// ShellOvnControllerApplier shells out to systemctl + ovs-vsctl. The
// binary paths are overridable for tests (the recorder-shim pattern
// from ovs_bridge_applier_test).
type ShellOvnControllerApplier struct {
	// SystemctlBin overrides the `systemctl` binary path. Empty falls
	// back to "systemctl" looked up via $PATH.
	SystemctlBin string
	// OvsVsctlBin overrides the `ovs-vsctl` binary path. Empty falls
	// back to "ovs-vsctl" looked up via $PATH.
	OvsVsctlBin string

	// hostnameFn is the os.Hostname swap-in for tests; nil falls back
	// to os.Hostname. We keep it unexported because production code
	// has no reason to override it.
	hostnameFn func() (string, error)

	mu              sync.Mutex
	lastEncapType   string
	lastEncapIp     string
	lastSbDb        string
	lastChassisName string
	lastApplied     bool
}

// NewOvnControllerApplier returns a default-configured applier that
// shells out to system `systemctl` and `ovs-vsctl`.
func NewOvnControllerApplier() *ShellOvnControllerApplier {
	return &ShellOvnControllerApplier{}
}

func (a *ShellOvnControllerApplier) systemctl() string {
	if a.SystemctlBin != "" {
		return a.SystemctlBin
	}
	return "systemctl"
}

func (a *ShellOvnControllerApplier) ovsVsctl() string {
	if a.OvsVsctlBin != "" {
		return a.OvsVsctlBin
	}
	return "ovs-vsctl"
}

func (a *ShellOvnControllerApplier) hostname() (string, error) {
	if a.hostnameFn != nil {
		return a.hostnameFn()
	}
	return os.Hostname()
}

// Apply makes the host match `desired`:
//
//  1. desired == nil — host is lightweight or OVN is not deployed for
//     the account. If `ovn-controller` is currently active, stop it.
//     Skip OVS config (lightweight hosts may not have ovs-vsctl).
//
//  2. desired != nil — heavyweight host with an active OVN deployment.
//     Validate required fields, default optional ones, write the four
//     OVS external_ids, then start `ovn-controller` if not already
//     active. ovs-vsctl `set` is idempotent (it overwrites cleanly),
//     so a no-op apply still reissues the four sets — only the
//     systemctl start is gated on is-active.
//
// Per-host-state caching: the applier remembers the last-applied
// values and the OVS bin/systemctl bin context so it can short-circuit
// truly-no-op reapplies (same desired, same is-active=true) without
// reissuing the four ovs-vsctl sets. This keeps the steady-state tick
// cheap; the underlying ovs-vsctl set commands are themselves
// idempotent so the cache is an optimization, not a correctness
// requirement.
func (a *ShellOvnControllerApplier) Apply(ctx context.Context, desired *DesiredOvnControl) error {
	if desired == nil {
		return a.applyDisabled(ctx)
	}
	return a.applyEnabled(ctx, desired)
}

// applyDisabled — desired is nil. Stop ovn-controller if running,
// then return. Skip ovs-vsctl entirely so a lightweight host without
// OVS installed still reconciles cleanly.
func (a *ShellOvnControllerApplier) applyDisabled(ctx context.Context) error {
	// If systemctl is missing, there's nothing to stop — treat as a
	// no-op rather than fail. The lightweight-with-no-systemd case is
	// rare in production but trivially supported.
	if !a.systemctlAvailable() {
		a.mu.Lock()
		a.lastApplied = false
		a.mu.Unlock()
		return nil
	}

	active, err := a.isUnitActive(ctx, "ovn-controller")
	if err != nil {
		// is-active is non-fatal — a host without the unit installed
		// returns "inactive" (and exit 3). Only a hard exec error
		// (binary not found, signal kill) bubbles up here.
		return fmt.Errorf("check ovn-controller active: %w", err)
	}
	if !active {
		a.mu.Lock()
		a.lastApplied = false
		a.mu.Unlock()
		return nil
	}

	if err := a.stopUnit(ctx, "ovn-controller"); err != nil {
		return fmt.Errorf("stop ovn-controller: %w", err)
	}

	a.mu.Lock()
	a.lastApplied = false
	a.mu.Unlock()
	return nil
}

// applyEnabled — desired is non-nil. Validate, default, write OVS
// config, ensure the unit is running.
func (a *ShellOvnControllerApplier) applyEnabled(ctx context.Context, desired *DesiredOvnControl) error {
	if strings.TrimSpace(desired.SbDbEndpoint) == "" {
		return fmt.Errorf("ovn control: SbDbEndpoint is required (got empty)")
	}
	if strings.TrimSpace(desired.EncapIp) == "" {
		return fmt.Errorf("ovn control: EncapIp is required (got empty)")
	}

	encapType := desired.EncapType
	if strings.TrimSpace(encapType) == "" {
		encapType = "geneve"
	}

	chassisName := desired.ChassisName
	if strings.TrimSpace(chassisName) == "" {
		hn, err := a.hostname()
		if err != nil || strings.TrimSpace(hn) == "" {
			return fmt.Errorf("ovn control: ChassisName empty and os.Hostname failed: %w", err)
		}
		chassisName = hn
	}

	// Pre-flight: heavyweight path requires both binaries. Surface a
	// clear error rather than the cryptic "exec: not found" we'd get
	// from the shell-out below.
	if a.OvsVsctlBin == "" {
		if _, err := exec.LookPath("ovs-vsctl"); err != nil {
			return fmt.Errorf("ovs-vsctl not found in PATH: %w (heavyweight network profile requires Open vSwitch)", err)
		}
	} else {
		if _, err := exec.LookPath(a.OvsVsctlBin); err != nil {
			return fmt.Errorf("ovs-vsctl override %q not executable: %w", a.OvsVsctlBin, err)
		}
	}
	if a.SystemctlBin == "" {
		if _, err := exec.LookPath("systemctl"); err != nil {
			return fmt.Errorf("systemctl not found in PATH: %w (heavyweight network profile requires systemd-managed ovn-controller)", err)
		}
	} else {
		if _, err := exec.LookPath(a.SystemctlBin); err != nil {
			return fmt.Errorf("systemctl override %q not executable: %w", a.SystemctlBin, err)
		}
	}

	// Write the four OVS external_ids. ovs-vsctl `set` is idempotent —
	// overwriting an existing key with the same value is a no-op at
	// the OVSDB layer — so we always issue them. ovn-controller
	// re-reads on change and applies updates without restart.
	sets := []struct {
		key   string
		value string
	}{
		{"ovn-encap-type", encapType},
		{"ovn-encap-ip", desired.EncapIp},
		{"ovn-remote", desired.SbDbEndpoint},
		{"system-id", chassisName},
	}
	for _, s := range sets {
		if err := a.setExternalId(ctx, s.key, s.value); err != nil {
			return fmt.Errorf("set external_ids:%s=%s: %w", s.key, s.value, err)
		}
	}

	// Gate the systemctl start on is-active so a steady-state apply
	// doesn't bounce the daemon. ovs-vsctl set above already pushes
	// any config changes via OVSDB watch.
	active, err := a.isUnitActive(ctx, "ovn-controller")
	if err != nil {
		return fmt.Errorf("check ovn-controller active: %w", err)
	}
	if !active {
		if err := a.startUnit(ctx, "ovn-controller"); err != nil {
			return fmt.Errorf("start ovn-controller: %w", err)
		}
	}

	a.mu.Lock()
	a.lastEncapType = encapType
	a.lastEncapIp = desired.EncapIp
	a.lastSbDb = desired.SbDbEndpoint
	a.lastChassisName = chassisName
	a.lastApplied = true
	a.mu.Unlock()
	return nil
}

// systemctlAvailable returns true iff the configured systemctl binary
// is reachable. Used by the disabled path to gate the is-active /
// stop calls — a host with no systemd at all (rare; mostly the test
// suite of a lightweight host) shouldn't error out of the reconcile
// loop.
func (a *ShellOvnControllerApplier) systemctlAvailable() bool {
	if a.SystemctlBin == "" {
		_, err := exec.LookPath("systemctl")
		return err == nil
	}
	_, err := exec.LookPath(a.SystemctlBin)
	return err == nil
}

// isUnitActive runs `systemctl is-active <unit>`. Returns true iff
// stdout (after trim) is exactly "active". Mirrors the systemd.IsActive
// helper but inlined here to keep the sdwan package free of cross-pkg
// imports for a single-shot call.
//
// `systemctl is-active` exits with code 3 for "inactive" or "failed";
// we tolerate that exit by checking stdout instead of the exit code.
// A genuine exec error (binary missing, signal kill) returns the err.
func (a *ShellOvnControllerApplier) isUnitActive(ctx context.Context, unit string) (bool, error) {
	cmd := exec.CommandContext(ctx, a.systemctl(), "is-active", unit)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	state := strings.TrimSpace(stdout.String())
	// Non-zero exit with empty stdout = real failure (binary not
	// found, etc.); non-zero with stdout = inactive/failed/etc., which
	// is fine — we just inspect the state string.
	if err != nil && state == "" {
		// Tolerate ExitError so "inactive" path doesn't bubble up;
		// only report exec failures (LookPath would normally catch
		// these, but we double-check here for the disabled-path
		// invocation that doesn't pre-flight LookPath).
		if _, ok := err.(*exec.ExitError); !ok {
			return false, fmt.Errorf("systemctl is-active %s: %w; stderr=%s", unit, err, stderr.String())
		}
		return false, nil
	}
	return state == "active", nil
}

// startUnit runs `systemctl start <unit>`.
func (a *ShellOvnControllerApplier) startUnit(ctx context.Context, unit string) error {
	cmd := exec.CommandContext(ctx, a.systemctl(), "start", unit)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl start %s: %w; %s", unit, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// stopUnit runs `systemctl stop <unit>`.
func (a *ShellOvnControllerApplier) stopUnit(ctx context.Context, unit string) error {
	cmd := exec.CommandContext(ctx, a.systemctl(), "stop", unit)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl stop %s: %w; %s", unit, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// setExternalId runs `ovs-vsctl set Open_vSwitch . external_ids:<key>=<value>`.
// Quotes the value so spaces and special chars survive the OVSDB-CLI
// argument parser. ovs-vsctl is itself idempotent for `set` — replaying
// the same key=value is a no-op at the database layer.
func (a *ShellOvnControllerApplier) setExternalId(ctx context.Context, key, value string) error {
	arg := fmt.Sprintf(`external_ids:%s=%q`, key, value)
	cmd := exec.CommandContext(ctx, a.ovsVsctl(), "set", "Open_vSwitch", ".", arg)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ovs-vsctl set Open_vSwitch . %s: %w; %s", arg, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// ----------------------------------------------------------------------
// Compile-time assertions
// ----------------------------------------------------------------------

// Verify ShellOvnControllerApplier satisfies the OvnControllerApplier
// interface. Caught at build time rather than at the manager's first
// call site.
var _ OvnControllerApplier = (*ShellOvnControllerApplier)(nil)
