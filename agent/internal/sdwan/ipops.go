// ipops.go — small helpers for `ip` subcommand idempotency. Extracted
// to keep four bridge/wg/vip applier files from independently drifting
// on which iproute2 error messages constitute "already in the desired
// state" vs an actual failure.
package sdwan

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// iproute2 has emitted different messages over time for the "you're
// trying to add an address that's already there" case:
//
//   - older iproute2 (Ubuntu 22.04 noble pre-update, Debian 11):
//     "RTNETLINK answers: File exists"
//   - newer iproute2 (Ubuntu 24.04, Debian 12+, recent distros):
//     "Error: ipv6: address already assigned."
//     "Error: ipv4: Address already assigned."
//
// All three substring forms exist in the wild on hosts we currently
// target; pick whichever matches the running ip binary. Without this,
// the agent's reconcile loop spammed the newer-iproute2 message every
// tick on any node whose address was already correctly applied — see
// the long comment in wg_applier.go's apply path for context.
func isIPAddrAddAlreadyExistsErr(msg string) bool {
	return strings.Contains(msg, "File exists") ||
		strings.Contains(msg, "address already assigned") ||
		strings.Contains(msg, "Address already assigned")
}

// reconcileAddrs adds any CIDR in `desired` that isn't currently on
// the interface, and removes any address that's on the interface but
// not in `desired`. Uses a normalize-then-compare strategy so
// different valid representations of the same CIDR (uppercase v6,
// leading-zero prefix) compare equal. `ip` is the iproute2 binary path
// the caller resolves from its applier (e.g. a.ip()).
func reconcileAddrs(ctx context.Context, ip, ifname string, desired []string) error {
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

	actual, err := listAddrs(ctx, ip, ifname)
	if err != nil {
		return fmt.Errorf("list addrs: %w", err)
	}

	// Add missing.
	for key, original := range desiredByKey {
		if _, ok := actual[key]; ok {
			continue
		}
		if err := addAddr(ctx, ip, ifname, original); err != nil {
			return fmt.Errorf("add %s: %w", original, err)
		}
	}

	// Remove orphans.
	for key, original := range actual {
		if _, ok := desiredByKey[key]; ok {
			continue
		}
		_ = delAddr(ctx, ip, ifname, original)
	}
	return nil
}

// listAddrs returns key→original-cidr for addresses currently on the
// interface. Reads `ip -j addr show dev <ifname>` and parses the JSON.
// The shape is `[{ "addr_info": [{"family":"inet|inet6","local":"<ip>","prefixlen":N}, ...] }]`.
func listAddrs(ctx context.Context, ip, ifname string) (map[string]string, error) {
	cmd := exec.CommandContext(ctx, ip, "-j", "addr", "show", "dev", ifname)
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

// addAddr installs `cidr` on `ifname`, tolerating the "already there"
// case across old + new iproute2 message variants (see
// isIPAddrAddAlreadyExistsErr for the substring catalog).
func addAddr(ctx context.Context, ip, ifname, cidr string) error {
	cmd := exec.CommandContext(ctx, ip, "addr", "add", cidr, "dev", ifname)
	out, err := cmd.CombinedOutput()
	if err != nil {
		// Already there — fine. Helper covers both old + new iproute2 messages
		// (see ipops.go for the substring catalog).
		if isIPAddrAddAlreadyExistsErr(string(out)) {
			return nil
		}
		return fmt.Errorf("ip addr add %s dev %s: %w; %s", cidr, ifname, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// delAddr removes `cidr` from `ifname`. Best-effort: a missing address
// is not an error worth surfacing (the desired end state — absent — is
// already met), so the command result is intentionally ignored.
func delAddr(ctx context.Context, ip, ifname, cidr string) error {
	cmd := exec.CommandContext(ctx, ip, "addr", "del", cidr, "dev", ifname)
	_, _ = cmd.CombinedOutput()
	return nil
}

// captureLinkShow runs `ip -d -j link show type <linkType>` and returns
// its stdout. linkType is the iproute2 link kind ("bridge", "vrf", ...).
// On a nonzero exit with empty stdout it returns ("", nil) — some
// kernels exit nonzero when no links of the requested type exist, which
// callers treat as "zero links" rather than a fatal error.
func captureLinkShow(ctx context.Context, ip, linkType string) (string, error) {
	cmd := exec.CommandContext(ctx, ip, "-d", "-j", "link", "show", "type", linkType)
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
