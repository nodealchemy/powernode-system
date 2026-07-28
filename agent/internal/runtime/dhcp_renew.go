package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// leasesDir is where systemd-networkd records a DHCP lease per link, named by
// ifindex. A var so tests can point it at a temp dir.
var leasesDir = "/run/systemd/netif/leases"

// sysClassNet is the ifindex → interface-name map. A var for the same reason.
var sysClassNet = "/sys/class/net"

// RenewDHCPLeases re-sends a DHCP request on every link that currently holds a
// lease, so the server immediately learns the hostname we announce.
//
// WHY THIS IS NEEDED. The announced-hostname drop-in
// (10-dhcp.network.d/50-powernode-hostname.conf) only takes effect on the NEXT
// DHCP request. But the FIRST lease of every boot is acquired in the initramfs,
// driven by `ip=dhcp` on the kernel cmdline through the generated
// 71-default.network — long before the composed root (and therefore that
// drop-in) exists, and while the hostname is still "localhost". Post-pivot
// networkd then adopts the lease that is already held rather than re-requesting.
//
// On a fleet whose DHCP server publishes DNS from the client-supplied hostname,
// that means the node's own A record is wrong or missing until the lease renews
// — T1 on this fleet is an hour. Measured on ops-hub 2026-07-28:
//
//	04:10:32 localhost systemd-networkd[196]: DHCPv4 address 10.125.0.227 acquired
//	04:10:43 ops-hub   systemd-networkd[561]: Configuring with 10-dhcp.network
//
// and for the rest of that window every agent call failed with
// `lookup ops-hub.ipnode.us: no such host`. That window is exactly when the
// agent must heartbeat to bless a boot slot, promote a pending composition and
// sync operator SSH keys, so all three silently failed while the node looked
// healthy.
//
// Best-effort by design: a node with no leases, no networkctl, or a
// statically-addressed link simply has nothing to do here, and none of those is
// an error worth failing a reconcile tick over.
func RenewDHCPLeases(ctx context.Context, r mount.Runner) error {
	links, err := linksWithLease()
	if err != nil || len(links) == 0 {
		return err
	}

	var failures []string
	for _, ifname := range links {
		if rerr := r.Run(ctx, "networkctl", "renew", ifname); rerr != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", ifname, rerr))
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("networkctl renew: %s", strings.Join(failures, "; "))
	}
	return nil
}

// linksWithLease maps each lease file (named by ifindex) to its interface name.
// Renewing only leased links avoids poking statically-configured interfaces,
// which have no lease to renew and would just log errors.
func linksWithLease() ([]string, error) {
	entries, err := os.ReadDir(leasesDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // no networkd leases on this node — nothing to do
		}
		return nil, err
	}

	byIndex := ifindexToName()
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if name, ok := byIndex[e.Name()]; ok {
			names = append(names, name)
		}
	}
	return names, nil
}

func ifindexToName() map[string]string {
	out := map[string]string{}
	ifaces, err := os.ReadDir(sysClassNet)
	if err != nil {
		return out
	}
	for _, ifc := range ifaces {
		if ifc.Name() == "lo" {
			continue
		}
		idx, rerr := os.ReadFile(filepath.Join(sysClassNet, ifc.Name(), "ifindex"))
		if rerr != nil {
			continue
		}
		out[strings.TrimSpace(string(idx))] = ifc.Name()
	}
	return out
}
