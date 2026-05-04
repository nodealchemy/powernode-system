// vip_applier.go — slice 9b: configure VIPs on the local loopback so the
// kernel claims the VIP addresses (and any service bound to them
// receives the traffic).
//
// Topology compiler arranges the *routing* (each other peer's [Peer]
// section gets the VIP CIDR in AllowedIPs pointing at the holder); this
// applier handles the *acceptance* on the holder side. Without it, the
// holder's kernel sees an inbound packet for an address it doesn't
// claim and drops it as "not for me."
//
// Idempotency: we read `ip -o addr show dev lo`, diff against the
// desired VIP set, add missing, remove orphans we previously managed.
// We never touch the loopback defaults (127.0.0.1/8, ::1/128) — those
// are kernel-managed and removing them breaks every loopback service.
//
// Slice 9b of the SDWAN plan.

package sdwan

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os/exec"
	"strings"
)

// VipApplier abstracts the loopback configuration step so the manager
// is testable without touching kernel state.
type VipApplier interface {
	ApplyVips(ctx context.Context, desired []VipConf) error
}

// ShellVipApplier shells out to `ip addr` — same pattern as
// NftablesApplier shells out to `nft`. No new Go dependencies.
type ShellVipApplier struct {
	// IpBin overrides the `ip` binary path for tests; defaults to "ip".
	IpBin string
}

func NewShellVipApplier() *ShellVipApplier {
	return &ShellVipApplier{}
}

func (a *ShellVipApplier) ApplyVips(ctx context.Context, desired []VipConf) error {
	desiredSet := make(map[string]VipConf, len(desired))
	for _, v := range desired {
		key, err := normalizeCidr(v.Cidr)
		if err != nil {
			continue
		}
		desiredSet[key] = v
	}

	current, err := a.listLoopbackAddrs(ctx)
	if err != nil {
		return fmt.Errorf("list lo addrs: %w", err)
	}

	// Phase 1 — add missing.
	for key, v := range desiredSet {
		if _, ok := current[key]; ok {
			continue
		}
		if err := a.addAddr(ctx, v.Cidr); err != nil {
			return fmt.Errorf("add %s: %w", v.Cidr, err)
		}
	}

	// Phase 2 — remove orphans. We only delete addresses that look like
	// VIP candidates (single-host /32 or /128 in non-loopback ranges).
	// This conservative heuristic protects loopback from accidental
	// removal when the desired set is empty (e.g. transient "no VIPs"
	// state during pause/resume).
	for key, cidr := range current {
		if _, ok := desiredSet[key]; ok {
			continue
		}
		if isLoopbackDefault(cidr) || !looksLikeVip(cidr) {
			continue
		}
		_ = a.delAddr(ctx, cidr)
	}
	return nil
}

// listLoopbackAddrs reads `ip -o addr show dev lo` and returns a map of
// canonical-CIDR → original-CIDR. The canonical form is what we use for
// set membership; the original form is what we hand back to `ip addr
// del` (preserves whatever flags the kernel reports).
func (a *ShellVipApplier) listLoopbackAddrs(ctx context.Context) (map[string]string, error) {
	bin := a.IpBin
	if bin == "" {
		bin = "ip"
	}
	cmd := exec.CommandContext(ctx, bin, "-o", "addr", "show", "dev", "lo")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ip addr show: %w; stderr=%s", err, stderr.String())
	}
	out := make(map[string]string)
	for _, line := range strings.Split(stdout.String(), "\n") {
		fields := strings.Fields(line)
		// "1: lo    inet 127.0.0.1/8 scope host lo ..."
		// "1: lo    inet6 ::1/128 scope host ..."
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

func (a *ShellVipApplier) addAddr(ctx context.Context, cidr string) error {
	bin := a.IpBin
	if bin == "" {
		bin = "ip"
	}
	cmd := exec.CommandContext(ctx, bin, "addr", "add", cidr, "dev", "lo")
	out, err := cmd.CombinedOutput()
	if err != nil {
		// "RTNETLINK answers: File exists" — already there, tolerate.
		if strings.Contains(string(out), "File exists") {
			return nil
		}
		return fmt.Errorf("ip addr add: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellVipApplier) delAddr(ctx context.Context, cidr string) error {
	bin := a.IpBin
	if bin == "" {
		bin = "ip"
	}
	cmd := exec.CommandContext(ctx, bin, "addr", "del", cidr, "dev", "lo")
	_, _ = cmd.CombinedOutput()
	return nil
}

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

func isLoopbackDefault(cidr string) bool {
	c := strings.TrimSpace(cidr)
	return c == "127.0.0.1/8" || c == "::1/128"
}

// looksLikeVip is a defensive heuristic — we only orphan-prune addresses
// that look like single-host VIP candidates so we don't accidentally
// delete operator-configured addresses on lo (rare, but possible for
// service binding).
func looksLikeVip(cidr string) bool {
	parts := strings.SplitN(cidr, "/", 2)
	if len(parts) != 2 {
		return false
	}
	ip := net.ParseIP(parts[0])
	if ip == nil {
		return false
	}
	switch parts[1] {
	case "32":
		return ip.To4() != nil
	case "128":
		return ip.To4() == nil
	}
	return false
}
