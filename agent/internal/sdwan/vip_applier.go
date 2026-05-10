// vip_applier.go — Phase N1a: configure VIP addresses on per-VRF
// dummy interfaces so a host that holds a VIP claims the address inside
// the right routing domain.
//
// Pre-N1a behaviour put every VIP on the global loopback (`lo`),
// which worked when each host belonged to at most one iBGP network
// because forwarding decisions all hit the kernel's main routing
// table. With multi-VRF, a VIP installed on `lo` is unreachable from
// VRF-bound BGP sessions because the source-address selection chooses
// the wrong egress (or fails) and the FIB doesn't route to `lo` from
// inside a non-default VRF. The fix: one dummy iface per VRF, bound
// to the VRF master device, and the VIP installed there.
//
// Layout:
//
//	d-sdwan-<network_handle>   type=dummy   master=sdwan-<handle>
//	  ↳ <vip_cidr> (one or more, /128 for v6 or /32 for v4)
//
// The leading `d-` (instead of the wordier `dummy-`) is dictated by
// Linux's IFNAMSIZ — 15 usable chars. With the platform's 6-char
// network handle the VRF master is `sdwan-<6>` (12 chars); the
// dummy is `d-sdwan-<6>` (14 chars). Wider prefixes overflow.
//
// Idempotency: we read `ip -j addr show` for every dummy iface we
// own (matched by the "d-sdwan-" prefix), diff against the desired
// set, add missing addresses, and remove orphans whose CIDRs are no
// longer desired on that VRF. Dummy ifaces with no remaining
// addresses are deleted. Dummy ifaces whose VRF is gone are reaped.
//
// The global loopback path is gone — VIP installation never touches
// `lo` again.
//
// Phase N1a of the in-house encrypted mesh overlay roadmap.

package sdwan

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os/exec"
	"sort"
	"strings"
)

// DesiredVip extends the legacy VipConf with the VRF binding the
// applier needs to install the address in the right routing domain.
// The platform's topology compiler stamps VrfName onto each VIP entry
// based on the network's HostVrfAssignment for the holder host.
type DesiredVip struct {
	Cidr    string
	VrfName string // e.g. "sdwan-abc12345"
}

// VipApplier abstracts per-VRF VIP installation. ShellVipApplier is
// the production implementation.
type VipApplier interface {
	ApplyVips(ctx context.Context, desired []VipConf) error
}

// ShellVipApplier shells out to `ip` for dummy-iface and address
// management.
type ShellVipApplier struct {
	IpBin string
}

func NewShellVipApplier() *ShellVipApplier {
	return &ShellVipApplier{}
}

func (a *ShellVipApplier) ip() string {
	if a.IpBin != "" {
		return a.IpBin
	}
	return "ip"
}

// ApplyVips makes the kernel's per-VRF dummy ifaces match `desired`.
// VipConf is sourced from the platform's TopologyCompiler; the new
// `vrf_name` field on each entry tells the applier which dummy iface
// the address belongs on.
//
// Steps:
//  1. Group desired VIPs by VRF.
//  2. For each VRF, ensure a `dummy-<vrfname>` dummy iface exists,
//     is up, and is bound to the VRF master device (idempotent).
//  3. Diff actual addresses on each dummy against desired; add
//     missing, delete orphans.
//  4. Reap dummy ifaces whose VRF is no longer present in desired.
//
// Tolerates a missing VrfName on a VipConf entry by skipping it with
// a recorded best-effort warning — this lets the agent keep working
// during the brief window between a network's creation and the
// platform stamping its HostVrfAssignment onto the VIP payload.
func (a *ShellVipApplier) ApplyVips(ctx context.Context, desired []VipConf) error {
	desiredByVRF := make(map[string]map[string]struct{})
	for _, v := range desired {
		vrfName := v.VrfName
		if vrfName == "" {
			// No VRF binding yet — skip rather than installing on `lo`
			// (which the legacy path did). The next reconcile after
			// the platform stamps vrf_name will pick it up.
			continue
		}
		key, err := normalizeCidr(v.Cidr)
		if err != nil {
			continue
		}
		if _, ok := desiredByVRF[vrfName]; !ok {
			desiredByVRF[vrfName] = make(map[string]struct{})
		}
		desiredByVRF[vrfName][key] = struct{}{}
	}

	currentDummies, err := a.listDummies(ctx)
	if err != nil {
		return fmt.Errorf("list dummies: %w", err)
	}

	// Pass 1 — ensure each desired VRF has its dummy iface configured
	// and the desired addresses installed.
	for vrfName, addrs := range desiredByVRF {
		dummyName := dummyNameForVRF(vrfName)
		if !linkExists(ctx, a.ip(), dummyName) {
			if err := a.createDummy(ctx, dummyName); err != nil {
				return fmt.Errorf("create dummy %s: %w", dummyName, err)
			}
		}
		if err := a.bindToVRF(ctx, dummyName, vrfName); err != nil {
			return fmt.Errorf("bind %s to %s: %w", dummyName, vrfName, err)
		}
		if err := a.bringUp(ctx, dummyName); err != nil {
			return fmt.Errorf("bring up %s: %w", dummyName, err)
		}

		actual, err := a.listAddrs(ctx, dummyName)
		if err != nil {
			return fmt.Errorf("list addrs for %s: %w", dummyName, err)
		}

		// Add missing — desired keys not present in actual.
		for key := range addrs {
			if _, ok := actual[key]; ok {
				continue
			}
			if err := a.addAddr(ctx, dummyName, key); err != nil {
				return fmt.Errorf("add %s on %s: %w", key, dummyName, err)
			}
		}

		// Remove orphan addresses — actual keys not present in desired.
		for key, original := range actual {
			if _, ok := addrs[key]; ok {
				continue
			}
			_ = a.delAddr(ctx, dummyName, original)
		}
	}

	// Pass 2 — reap dummies whose VRF is no longer wanted. Their
	// addresses are gone with them.
	for _, dummyName := range currentDummies {
		vrfName := vrfNameFromDummy(dummyName)
		if vrfName == "" {
			continue
		}
		if _, want := desiredByVRF[vrfName]; want {
			continue
		}
		_ = a.deleteLink(ctx, dummyName)
	}

	return nil
}

// dummyNameForVRF maps "sdwan-abc123" → "d-sdwan-abc123". The `d-`
// prefix is the shortest unambiguous marker that fits within Linux's
// IFNAMSIZ (15 usable chars) when combined with the 12-char VRF name
// (6-char network handle): "d-sdwan-abc123" is 14 chars. Wider
// prefixes (e.g., `dummy-`) overflow.
func dummyNameForVRF(vrfName string) string {
	return "d-" + vrfName
}

// vrfNameFromDummy is the inverse mapping; returns "" for ifaces that
// don't follow our naming convention.
func vrfNameFromDummy(dummyName string) string {
	if !strings.HasPrefix(dummyName, "d-sdwan-") {
		return ""
	}
	return strings.TrimPrefix(dummyName, "d-")
}

func (a *ShellVipApplier) listDummies(ctx context.Context) ([]string, error) {
	cmd := exec.CommandContext(ctx, a.ip(), "-o", "link", "show", "type", "dummy")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// `ip` returns nonzero on some kernels when no dummy ifaces
		// exist. Treat empty output as zero ifaces.
		if stdout.Len() == 0 {
			return nil, nil
		}
		return nil, fmt.Errorf("ip link show type dummy: %w; stderr=%s", err, stderr.String())
	}

	var names []string
	for _, line := range strings.Split(stdout.String(), "\n") {
		// "1: dummy-sdwan-abc12345: <BROADCAST,NOARP> mtu 1500 ..."
		parts := strings.SplitN(line, ": ", 3)
		if len(parts) < 2 {
			continue
		}
		raw := strings.TrimSpace(parts[1])
		// May carry an "@<lower>" suffix on linked devices; strip.
		if i := strings.Index(raw, "@"); i >= 0 {
			raw = raw[:i]
		}
		if !strings.HasPrefix(raw, "d-sdwan-") {
			continue
		}
		names = append(names, raw)
	}
	sort.Strings(names)
	return names, nil
}

func (a *ShellVipApplier) listAddrs(ctx context.Context, ifname string) (map[string]string, error) {
	cmd := exec.CommandContext(ctx, a.ip(), "-o", "addr", "show", "dev", ifname)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// Iface may have been concurrently removed; tolerate.
		if strings.Contains(stderr.String(), "does not exist") {
			return map[string]string{}, nil
		}
		return nil, fmt.Errorf("ip addr show dev %s: %w; stderr=%s", ifname, err, stderr.String())
	}
	out := make(map[string]string)
	for _, line := range strings.Split(stdout.String(), "\n") {
		fields := strings.Fields(line)
		for i, f := range fields {
			if (f == "inet" || f == "inet6") && i+1 < len(fields) {
				cidr := fields[i+1]
				if key, err := normalizeCidr(cidr); err == nil {
					out[key] = cidr
				}
			}
		}
	}
	return out, nil
}

func (a *ShellVipApplier) createDummy(ctx context.Context, name string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "add", name, "type", "dummy")
	out, err := cmd.CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "File exists") {
			return nil
		}
		return fmt.Errorf("ip link add %s type dummy: %w; %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellVipApplier) bindToVRF(ctx context.Context, ifname, vrfName string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "set", ifname, "master", vrfName)
	out, err := cmd.CombinedOutput()
	if err != nil {
		// `ip` is silent when the master is already correctly set, so
		// most calls return zero. When it errors, surface the message.
		return fmt.Errorf("ip link set %s master %s: %w; %s", ifname, vrfName, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellVipApplier) bringUp(ctx context.Context, ifname string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "set", ifname, "up")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip link set %s up: %w; %s", ifname, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellVipApplier) addAddr(ctx context.Context, ifname, cidr string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "addr", "add", cidr, "dev", ifname)
	out, err := cmd.CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "File exists") {
			return nil
		}
		return fmt.Errorf("ip addr add %s dev %s: %w; %s", cidr, ifname, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellVipApplier) delAddr(ctx context.Context, ifname, cidr string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "addr", "del", cidr, "dev", ifname)
	_, _ = cmd.CombinedOutput()
	return nil
}

func (a *ShellVipApplier) deleteLink(ctx context.Context, ifname string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "delete", ifname)
	out, err := cmd.CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "Cannot find device") {
			return nil
		}
		return fmt.Errorf("ip link delete %s: %w; %s", ifname, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// linkExists is shared with vrf_applier — package-level helper.
func linkExists(ctx context.Context, ipBin, name string) bool {
	cmd := exec.CommandContext(ctx, ipBin, "link", "show", name)
	if err := cmd.Run(); err != nil {
		return false
	}
	return true
}

// ---- Helpers carried over from the loopback-era applier ----

// normalizeCidr returns "<canonical-ip>/<mask>" — strips leading-zero
// IPv6 forms, lowercases hex, and zero-prefix-fills so two valid
// representations of the same CIDR compare equal.
func normalizeCidr(c string) (string, error) {
	c = strings.TrimSpace(c)
	if c == "" {
		return "", fmt.Errorf("empty cidr")
	}
	ip, ipnet, err := net.ParseCIDR(c)
	if err != nil {
		return "", err
	}
	ones, _ := ipnet.Mask.Size()
	return fmt.Sprintf("%s/%d", ip.String(), ones), nil
}
