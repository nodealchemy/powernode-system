// linux_bridge_applier.go — Phase O1: Linux-bridge backend for the
// BridgeApplier strategy. Shells out to `ip` for bridge creation,
// MTU + state management, and address reconcile.
//
// What this file owns:
//   * Create `pwnbr-*` bridges that are missing from kernel.
//   * Set MTU when DesiredBridge.MTU > 0 (the platform sends 0 to mean
//     "leave the kernel default at 1500"; we then issue no `mtu`
//     command on creation, but do reconcile MTU each tick when the
//     desired MTU is non-zero — even if the bridge already exists —
//     because tap-iface MTU drift is the most common operator-induced
//     breakage on bridges).
//   * Bring bridges UP unconditionally each tick (idempotent on the
//     kernel side; tolerates stale-link-down state introduced by
//     ifupdown's restart of /etc/network/interfaces).
//   * Reconcile addresses installed directly on the bridge: add any
//     CIDR in DesiredBridge.Cidrs that isn't present, delete any
//     address present that isn't in DesiredBridge.Cidrs.
//   * Reap orphan `pwnbr-*` bridges — bridges named with the platform
//     prefix that aren't in the desired set get `ip link del`. This is
//     best-effort: a bridge with tap interfaces still enslaved cannot
//     be deleted by the kernel, in which case we log the failure but
//     don't fail Apply (the next reconcile after the operator removes
//     the tap interfaces will succeed).
//
// What this file deliberately does NOT do:
//   * Doesn't manage tap interfaces or VM<->bridge attachment. That's
//     libvirt's job (driven by the LocalQemuProvider's domain XML
//     builder); the agent only ensures the bridge exists.
//   * Doesn't touch operator-installed bridges (`br0`, `virbr0`,
//     `docker0`, `pwnvbr0` from the manual setup era). The
//     `pwnbr-` prefix filter excludes them from listing + reaping.
//   * Doesn't attach bridges to VRFs — host-side VM bridges live in
//     the default routing context. Pod-overlay bridges (Phase O3+)
//     will be a separate concern with separate naming.
//
// Phase O1 of the OVS+OVN dual-profile networking roadmap.

package sdwan

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// bridgePrefix is the marker that identifies platform-managed
// bridges. Anything starting with this is fair game for delete + addr
// reconcile; everything else is operator territory and left alone.
const bridgePrefix = "pwnbr-"

// LinuxBridgeApplier is the Phase O1 BridgeApplier implementation.
// IpBin overrides the binary path for tests (the recorder shim
// pattern from vrf_applier_test).
type LinuxBridgeApplier struct {
	IpBin string
}

// NewLinuxBridgeApplier returns a default-configured applier that
// shells out to the system `ip` binary.
func NewLinuxBridgeApplier() *LinuxBridgeApplier {
	return &LinuxBridgeApplier{}
}

func (a *LinuxBridgeApplier) ip() string {
	if a.IpBin != "" {
		return a.IpBin
	}
	return "ip"
}

// Apply makes the kernel match `desired`:
//  1. Reads existing platform-owned bridges (`pwnbr-*`).
//  2. For each desired entry: create if missing, set MTU when
//     non-zero, bring up, reconcile addresses.
//  3. Reap orphan `pwnbr-*` bridges not in the desired set.
//
// Returns an error only on conditions that prevent any progress
// (e.g. failure to enumerate the current bridge set). Per-bridge
// errors are recorded and reconcile continues to the next entry —
// matches the contract the rest of the appliers in this package
// follow so a transient failure on one bridge doesn't block the
// host's other reconcile work.
func (a *LinuxBridgeApplier) Apply(ctx context.Context, desired []DesiredBridge) error {
	desiredByName := make(map[string]DesiredBridge, len(desired))
	for _, b := range desired {
		if b.Name == "" {
			// Defensive — the platform's allocator should never emit
			// an empty name, but skipping is safer than handing the
			// empty string to `ip link add`.
			continue
		}
		if b.Kind != "" && b.Kind != "linux" {
			// Phase O2 will add an OvsBridgeApplier; until then, an
			// entry tagged `kind=ovs` would be intended for the OVS
			// backend, not us. Skip silently — the OVS applier will
			// pick it up on hosts running the heavyweight profile.
			continue
		}
		desiredByName[b.Name] = b
	}

	current, err := a.listBridges(ctx)
	if err != nil {
		return fmt.Errorf("list bridges: %w", err)
	}

	// Pass 1 — create / update each desired bridge.
	for name, b := range desiredByName {
		if _, exists := current[name]; !exists {
			if err := a.createBridge(ctx, name); err != nil {
				return fmt.Errorf("create bridge %s: %w", name, err)
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

	// Pass 2 — reap orphan `pwnbr-*` bridges. Best-effort: a bridge
	// with tap interfaces still attached can't be deleted, and the
	// kernel returns "Device or resource busy" — we swallow that and
	// let the next reconcile (after the tap is detached) clean up.
	for name := range current {
		if _, want := desiredByName[name]; want {
			continue
		}
		_ = a.deleteBridge(ctx, name)
	}

	return nil
}

// listBridges returns name→struct{} for every platform-owned bridge
// (name starts with `pwnbr-`). Reads `ip -d -j link show type bridge`
// and parses the JSON; uses encoding/json because we need three fields
// per object (ifname + linkinfo.info_kind + filter on bridge prefix)
// and a hand-rolled parser would obscure the lookup.
func (a *LinuxBridgeApplier) listBridges(ctx context.Context) (map[string]struct{}, error) {
	out, err := a.captureLinkShow(ctx)
	if err != nil {
		// `ip` returns nonzero when no bridges exist on some kernel
		// versions. Treat empty-output failure as "no bridges yet".
		if out == "" {
			return map[string]struct{}{}, nil
		}
		return nil, err
	}

	parsed, err := parseLinkShow(out)
	if err != nil {
		return nil, err
	}

	filtered := make(map[string]struct{}, len(parsed))
	for name, kind := range parsed {
		if kind != "bridge" {
			continue
		}
		if !strings.HasPrefix(name, bridgePrefix) {
			continue
		}
		filtered[name] = struct{}{}
	}
	return filtered, nil
}

func (a *LinuxBridgeApplier) captureLinkShow(ctx context.Context) (string, error) {
	cmd := exec.CommandContext(ctx, a.ip(), "-d", "-j", "link", "show", "type", "bridge")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// Empty output + nonzero exit = no bridges of this type on
		// this kernel. Treat as zero bridges rather than fatal.
		if stdout.Len() == 0 {
			return "", nil
		}
		return stdout.String(), fmt.Errorf("ip link show: %w; stderr=%s", err, stderr.String())
	}
	return stdout.String(), nil
}

func (a *LinuxBridgeApplier) createBridge(ctx context.Context, name string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "add", name, "type", "bridge")
	out, err := cmd.CombinedOutput()
	if err != nil {
		// Race-tolerant: another reconcile may have raced ahead.
		if strings.Contains(string(out), "File exists") {
			return nil
		}
		return fmt.Errorf("ip link add: %w; %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *LinuxBridgeApplier) deleteBridge(ctx context.Context, name string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "delete", name)
	out, err := cmd.CombinedOutput()
	if err != nil {
		// Already gone — fine.
		if strings.Contains(string(out), "Cannot find device") {
			return nil
		}
		// "Device or resource busy" — bridge still has slaves; the
		// next reconcile after the operator detaches them will
		// succeed. Don't fail the whole Apply.
		return fmt.Errorf("ip link delete %s: %w; %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *LinuxBridgeApplier) setMTU(ctx context.Context, name string, mtu int) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "set", name, "mtu", strconv.Itoa(mtu))
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip link set %s mtu %d: %w; %s", name, mtu, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *LinuxBridgeApplier) bringUp(ctx context.Context, name string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "set", name, "up")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip link set %s up: %w; %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// reconcileAddrs adds any CIDR in `desired` that isn't currently on
// the bridge, and removes any address that's on the bridge but not in
// `desired`. Uses the same normalize-then-compare strategy as
// vip_applier so different valid representations of the same CIDR
// (uppercase v6, leading-zero prefix) compare equal.
func (a *LinuxBridgeApplier) reconcileAddrs(ctx context.Context, ifname string, desired []string) error {
	desiredByKey := make(map[string]string, len(desired))
	for _, c := range desired {
		key, err := normalizeCidr(c)
		if err != nil {
			// Bad CIDR from the platform — skip. Don't fail the whole
			// reconcile; the next config push can correct it.
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
// bridge. Reads `ip -j addr show dev <ifname>` and parses the JSON.
// The shape is `[{ "addr_info": [{"family":"inet|inet6","local":"<ip>","prefixlen":N}, ...] }]`.
func (a *LinuxBridgeApplier) listAddrs(ctx context.Context, ifname string) (map[string]string, error) {
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

func (a *LinuxBridgeApplier) addAddr(ctx context.Context, ifname, cidr string) error {
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

func (a *LinuxBridgeApplier) delAddr(ctx context.Context, ifname, cidr string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "addr", "del", cidr, "dev", ifname)
	_, _ = cmd.CombinedOutput()
	return nil
}

// ----------------------------------------------------------------------
// JSON parsers — split out for direct unit testing.
// ----------------------------------------------------------------------

// linkShowEntry is the minimal subset of the `ip -d -j link show` shape
// we care about. Other fields (mtu, qdisc, etc.) are not relevant to
// the applier's reconcile decisions, so we let json.Unmarshal drop them.
type linkShowEntry struct {
	IfName   string `json:"ifname"`
	LinkInfo struct {
		InfoKind string `json:"info_kind"`
	} `json:"linkinfo"`
}

// parseLinkShow extracts (ifname, kind) pairs from the JSON output of
// `ip -d -j link show type bridge`. Returns a name→kind map. Empty
// input produces an empty map without error.
func parseLinkShow(out string) (map[string]string, error) {
	out = strings.TrimSpace(out)
	if out == "" {
		return map[string]string{}, nil
	}
	var entries []linkShowEntry
	if err := json.Unmarshal([]byte(out), &entries); err != nil {
		return nil, fmt.Errorf("parse link-show json: %w", err)
	}
	result := make(map[string]string, len(entries))
	for _, e := range entries {
		if e.IfName == "" {
			continue
		}
		result[e.IfName] = e.LinkInfo.InfoKind
	}
	return result, nil
}

// addrShowEntry mirrors the `ip -j addr show dev <ifname>` shape.
type addrShowEntry struct {
	IfName   string         `json:"ifname"`
	AddrInfo []addrInfoItem `json:"addr_info"`
}

type addrInfoItem struct {
	Family    string `json:"family"`
	Local     string `json:"local"`
	PrefixLen int    `json:"prefixlen"`
}

// parseAddrShow extracts addresses from the JSON output of
// `ip -j addr show dev <name>`. Returns a normalized-key→original-cidr
// map suitable for the diff-and-reconcile pattern in reconcileAddrs.
func parseAddrShow(out string) (map[string]string, error) {
	out = strings.TrimSpace(out)
	if out == "" {
		return map[string]string{}, nil
	}
	var entries []addrShowEntry
	if err := json.Unmarshal([]byte(out), &entries); err != nil {
		return nil, fmt.Errorf("parse addr-show json: %w", err)
	}
	result := make(map[string]string)
	for _, e := range entries {
		for _, a := range e.AddrInfo {
			if a.Local == "" {
				continue
			}
			cidr := fmt.Sprintf("%s/%d", a.Local, a.PrefixLen)
			key, err := normalizeCidr(cidr)
			if err != nil {
				continue
			}
			result[key] = cidr
		}
	}
	return result, nil
}
