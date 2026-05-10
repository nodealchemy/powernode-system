// ovs_bridge_applier.go — Phase O2: Open vSwitch backend for the
// BridgeApplier strategy. Shells out to `ovs-vsctl` for bridge
// lifecycle and to `ip` for L3 address management on the bridge's
// internal port (which the kernel exposes under the bridge's name,
// the same way it does for a Linux bridge). This lets us share the
// address-reconcile logic with linux_bridge_applier.go: the kernel
// doesn't care which control plane manages the bridge — `ip addr`
// operates on the named iface either way.
//
// What this file owns:
//   * Create `pwnbr-*` OVS bridges that are missing from ovs-vsctl's
//     bridge table.
//   * Set MTU when DesiredBridge.MTU > 0 by writing `mtu_request` on
//     the bridge's internal port. OVS reads mtu_request and applies it
//     to the in-kernel iface; the result is identical to `ip link set
//     <name> mtu N`. We use mtu_request rather than direct `ip link`
//     so the desired value is recorded in the OVS database — restarts
//     of ovs-vswitchd will reapply it without an external poke.
//   * Bring bridges UP via `ip link set <name> up`. OVS does not
//     auto-up its internal port on most distros, and even when it
//     does, calling `ip link set up` twice is harmless.
//   * Reconcile addresses installed directly on the bridge — same
//     CIDR diff as LinuxBridgeApplier.reconcileAddrs, sharing the
//     parseAddrShow + normalizeCidr helpers.
//   * Reap orphan `pwnbr-*` OVS bridges via `ovs-vsctl --if-exists
//     del-br`. Best-effort: a bridge with active ports may fail to
//     delete on some configurations; we log via the returned error
//     pathway and let the next reconcile retry.
//
// What this file deliberately does NOT do:
//   * Doesn't manage flow rules, controllers, or per-port OpenFlow
//     state. Bridge lifecycle only — the OpenFlow control plane lands
//     in a later phase together with OVN integration.
//   * Doesn't manage tap interfaces or VM<->bridge attachment. The
//     libvirt domain XML builder still owns that side; the agent only
//     ensures the bridge exists for libvirt to attach into.
//   * Doesn't touch operator-installed bridges (`br0`, `virbr0`,
//     `docker0`) or Linux-backed `pwnbr-*` bridges. The `pwnbr-`
//     prefix bounds reaping; the Kind="ovs" filter on input keeps
//     the OVS and Linux appliers from racing on the same DesiredBridge
//     entries.
//   * Doesn't re-implement the Linux applier's empty-name / wrong-kind
//     filters as separate logic — the inversion of those rules
//     (accept Kind="ovs", skip everything else) is what cleanly
//     partitions the bridge namespace between the two backends.
//
// Phase O2 of the OVS+OVN dual-profile networking roadmap.

package sdwan

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// ShellOvsBridgeApplier is the Phase O2 BridgeApplier implementation
// backed by Open vSwitch. OvsVsctlBin and IpBin override the binary
// paths for tests (the recorder shim pattern from
// linux_bridge_applier_test).
type ShellOvsBridgeApplier struct {
	// OvsVsctlBin overrides the `ovs-vsctl` binary path. Empty falls
	// back to "ovs-vsctl" looked up via $PATH.
	OvsVsctlBin string
	// IpBin overrides the `ip` binary path. Empty falls back to "ip".
	// Used only for `ip link set <name> up` and `ip addr` reads/writes —
	// OVS owns the bridge lifecycle but L3 addresses are still kernel
	// state addressed by iface name.
	IpBin string
}

// NewOvsBridgeApplier returns a default-configured applier that shells
// out to the system `ovs-vsctl` and `ip` binaries.
func NewOvsBridgeApplier() *ShellOvsBridgeApplier {
	return &ShellOvsBridgeApplier{}
}

func (a *ShellOvsBridgeApplier) ovsVsctl() string {
	if a.OvsVsctlBin != "" {
		return a.OvsVsctlBin
	}
	return "ovs-vsctl"
}

func (a *ShellOvsBridgeApplier) ip() string {
	if a.IpBin != "" {
		return a.IpBin
	}
	return "ip"
}

// Apply makes OVS + the kernel match `desired`:
//  1. Verify `ovs-vsctl` is reachable; return a clear error if not.
//  2. Read existing platform-owned OVS bridges (`pwnbr-*`).
//  3. For each desired entry tagged Kind="ovs": create if missing,
//     set MTU when non-zero, bring up, reconcile addresses.
//  4. Reap orphan `pwnbr-*` OVS bridges not in the desired set.
//
// Returns an error only on conditions that prevent any progress
// (e.g. ovs-vsctl missing, failure to enumerate the current bridge
// set). Per-bridge errors abort that bridge but don't stop the loop —
// matches LinuxBridgeApplier's contract so the manager's Reconcile()
// stays alive across transient failures.
func (a *ShellOvsBridgeApplier) Apply(ctx context.Context, desired []DesiredBridge) error {
	// Defensive: if ovs-vsctl isn't installed, the platform should
	// never have stamped any Kind="ovs" entries for this host — but
	// surface a clear error rather than a cryptic "exec: not found".
	// We resolve via $PATH unless OvsVsctlBin is an explicit absolute
	// path (tests pass an absolute path to the recorder shim).
	if a.OvsVsctlBin == "" {
		if _, err := exec.LookPath("ovs-vsctl"); err != nil {
			return fmt.Errorf("ovs-vsctl not found in PATH: %w (heavyweight network profile requires Open vSwitch)", err)
		}
	} else {
		// Explicit override — verify the file actually exists. This
		// catches misconfiguration (typoed path) and the test path
		// that intentionally points at a nonexistent binary.
		if _, err := exec.LookPath(a.OvsVsctlBin); err != nil {
			return fmt.Errorf("ovs-vsctl override %q not executable: %w", a.OvsVsctlBin, err)
		}
	}

	desiredByName := make(map[string]DesiredBridge, len(desired))
	for _, b := range desired {
		if b.Name == "" {
			// Defensive — the platform's allocator should never emit
			// an empty name; skip rather than hand "" to ovs-vsctl.
			continue
		}
		// Inverse of LinuxBridgeApplier's filter: accept "ovs", skip
		// everything else. Empty Kind defaults to Linux per the
		// platform compiler, so we skip it too.
		if b.Kind != "ovs" {
			continue
		}
		desiredByName[b.Name] = b
	}

	current, err := a.listBridges(ctx)
	if err != nil {
		return fmt.Errorf("list ovs bridges: %w", err)
	}

	// Pass 1 — create / update each desired bridge.
	for name, b := range desiredByName {
		if _, exists := current[name]; !exists {
			if err := a.createBridge(ctx, name); err != nil {
				return fmt.Errorf("create ovs bridge %s: %w", name, err)
			}
		}
		if b.MTU > 0 {
			if err := a.setMTU(ctx, name, b.MTU); err != nil {
				return fmt.Errorf("set mtu on %s: %w", name, err)
			}
		}
		if err := a.bringUp(ctx, name); err != nil {
			return fmt.Errorf("bring up %s: %w", name, err)
		}
		if err := a.reconcileAddrs(ctx, name, b.Cidrs); err != nil {
			return fmt.Errorf("reconcile addrs on %s: %w", name, err)
		}
	}

	// Pass 2 — reap orphan `pwnbr-*` OVS bridges. Best-effort: OVS is
	// generally permissive about del-br with active ports (more so
	// than the Linux bridge driver), but we still tolerate failure so
	// a single stuck bridge doesn't block the rest of the reconcile.
	for name := range current {
		if _, want := desiredByName[name]; want {
			continue
		}
		_ = a.deleteBridge(ctx, name)
	}

	return nil
}

// listBridges returns name→struct{} for every platform-owned OVS
// bridge (name starts with `pwnbr-`). Reads `ovs-vsctl list-br` which
// emits one bridge name per line.
func (a *ShellOvsBridgeApplier) listBridges(ctx context.Context) (map[string]struct{}, error) {
	cmd := exec.CommandContext(ctx, a.ovsVsctl(), "list-br")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// Empty output + nonzero exit = no bridges. Treat as zero
		// rather than fatal so a fresh OVS install (no bridges yet)
		// doesn't block the first reconcile.
		if stdout.Len() == 0 {
			return map[string]struct{}{}, nil
		}
		return nil, fmt.Errorf("ovs-vsctl list-br: %w; stderr=%s", err, stderr.String())
	}
	return parseListBr(stdout.String()), nil
}

// parseListBr extracts platform-owned bridge names from `ovs-vsctl
// list-br` output (one bridge per line, newline-separated). Filters
// to `pwnbr-*` so operator-installed OVS bridges (e.g. `br-int` from
// a manual OVN install) are left alone. Split out from listBridges
// for direct unit testing.
func parseListBr(out string) map[string]struct{} {
	result := make(map[string]struct{})
	for _, line := range strings.Split(out, "\n") {
		name := strings.TrimSpace(line)
		if name == "" {
			continue
		}
		if !strings.HasPrefix(name, bridgePrefix) {
			continue
		}
		result[name] = struct{}{}
	}
	return result
}

func (a *ShellOvsBridgeApplier) createBridge(ctx context.Context, name string) error {
	// --may-exist makes add-br idempotent; ovs-vsctl returns 0 if the
	// bridge is already present, matching the contract of `ip link
	// add` plus our `File exists` swallow in the Linux applier.
	cmd := exec.CommandContext(ctx, a.ovsVsctl(), "--may-exist", "add-br", name)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ovs-vsctl add-br %s: %w; %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellOvsBridgeApplier) deleteBridge(ctx context.Context, name string) error {
	// --if-exists makes del-br idempotent; tolerates a bridge that
	// was already removed by an out-of-band operator or a prior
	// reconcile race.
	cmd := exec.CommandContext(ctx, a.ovsVsctl(), "--if-exists", "del-br", name)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ovs-vsctl del-br %s: %w; %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// setMTU writes mtu_request on the bridge's internal port. Every OVS
// bridge has an internal port with the same name as the bridge; that
// port's mtu_request becomes the bridge's MTU and is persisted in the
// OVS database, so an ovs-vswitchd restart re-applies it without us
// poking again.
func (a *ShellOvsBridgeApplier) setMTU(ctx context.Context, name string, mtu int) error {
	arg := fmt.Sprintf("mtu_request=%d", mtu)
	cmd := exec.CommandContext(ctx, a.ovsVsctl(), "set", "Interface", name, arg)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ovs-vsctl set Interface %s mtu_request=%d: %w; %s", name, mtu, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// bringUp issues `ip link set <name> up`. Required because OVS does
// not auto-up the bridge's internal port on most distros — and it's
// idempotent on the kernel side, so calling it every tick is cheap.
func (a *ShellOvsBridgeApplier) bringUp(ctx context.Context, name string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "set", name, "up")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip link set %s up: %w; %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// reconcileAddrs adds any CIDR in `desired` that isn't currently on
// the bridge, and removes any address that's on the bridge but not in
// `desired`. Identical strategy to LinuxBridgeApplier.reconcileAddrs:
// the kernel sees the OVS internal port under the bridge's name, so
// the same `ip addr add/del/show` commands work without modification.
// Shares the normalizeCidr + parseAddrShow helpers from the Linux
// applier so different valid representations of the same CIDR
// (uppercase v6, leading-zero prefix) compare equal.
func (a *ShellOvsBridgeApplier) reconcileAddrs(ctx context.Context, ifname string, desired []string) error {
	desiredByKey := make(map[string]string, len(desired))
	for _, c := range desired {
		key, err := normalizeCidr(c)
		if err != nil {
			// Bad CIDR from the platform — skip; the next config push
			// can correct it without us aborting the whole reconcile.
			continue
		}
		desiredByKey[key] = c
	}

	actual, err := a.listAddrs(ctx, ifname)
	if err != nil {
		return fmt.Errorf("list addrs: %w", err)
	}

	// Add missing.
	for key, original := range desiredByKey {
		if _, ok := actual[key]; ok {
			continue
		}
		if err := a.addAddr(ctx, ifname, original); err != nil {
			return fmt.Errorf("add %s: %w", original, err)
		}
	}

	// Remove orphans.
	for key, original := range actual {
		if _, ok := desiredByKey[key]; ok {
			continue
		}
		_ = a.delAddr(ctx, ifname, original)
	}
	return nil
}

// listAddrs returns key→original-cidr for addresses currently on the
// bridge's internal port. Same shape as LinuxBridgeApplier.listAddrs;
// reads `ip -j addr show dev <ifname>` and parses the JSON via the
// shared parseAddrShow helper.
func (a *ShellOvsBridgeApplier) listAddrs(ctx context.Context, ifname string) (map[string]string, error) {
	cmd := exec.CommandContext(ctx, a.ip(), "-j", "addr", "show", "dev", ifname)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// Iface may have been concurrently removed; tolerate.
		if strings.Contains(stderr.String(), "does not exist") {
			return map[string]string{}, nil
		}
		// Empty stdout on some kernels when the iface has no addrs.
		if stdout.Len() == 0 {
			return map[string]string{}, nil
		}
		return nil, fmt.Errorf("ip addr show dev %s: %w; stderr=%s", ifname, err, stderr.String())
	}
	return parseAddrShow(stdout.String())
}

func (a *ShellOvsBridgeApplier) addAddr(ctx context.Context, ifname, cidr string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "addr", "add", cidr, "dev", ifname)
	out, err := cmd.CombinedOutput()
	if err != nil {
		// Already there — fine.
		if strings.Contains(string(out), "File exists") {
			return nil
		}
		return fmt.Errorf("ip addr add %s dev %s: %w; %s", cidr, ifname, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellOvsBridgeApplier) delAddr(ctx context.Context, ifname, cidr string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "addr", "del", cidr, "dev", ifname)
	_, _ = cmd.CombinedOutput()
	return nil
}

// ----------------------------------------------------------------------
// Compile-time assertions
// ----------------------------------------------------------------------

// Verify ShellOvsBridgeApplier satisfies the BridgeApplier interface.
// Caught at build time rather than at the manager's first call site.
var _ BridgeApplier = (*ShellOvsBridgeApplier)(nil)
