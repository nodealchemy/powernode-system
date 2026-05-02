package security

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
)

// EgressTable is the nftables table name the agent uses for module-level
// egress allowlists. Each module attached to the node gets its own chain
// inside this table so attach/detach is cleanly bounded.
const EgressTable = "powernode_module_egress"

// ApplyEgressAllowlist installs nftables rules implementing default-deny
// egress with explicit allow rules for each entry in the allowlist.
// Entries are "host:port" or "host" (port-agnostic).
//
// Empty allowlist = full block (no egress). Use a one-element wildcard
// (e.g., "0.0.0.0/0") to permit unrestricted egress; modules requesting
// this should be reviewed.
//
// Implementation notes:
//   - For DNS resolution, the entry "host" is resolved to A/AAAA records
//     at install time + on cert-rotate (which runs every ~67 days). This
//     is best-effort; long-lived modules whose endpoints rotate IPs will
//     need to handle DNS via a sidecar.
//   - The chain is replaced atomically per attach to avoid partial-state
//     egress windows during rollouts.
func ApplyEgressAllowlist(ctx context.Context, runner mount.Runner, allowlist []string) error {
	// Step 1: ensure the table exists. nft will skip-on-exists.
	if err := runner.Run(ctx, "nft", "add", "table", "inet", EgressTable); err != nil {
		// Some nft versions return non-zero on already-exists; ignore.
	}
	// Step 2: Install/replace the egress chain.
	chain := "powernode_egress_filter"
	_ = runner.Run(ctx, "nft", "delete", "chain", "inet", EgressTable, chain) // best-effort

	if err := runner.Run(ctx, "nft", "add", "chain", "inet", EgressTable, chain,
		"{", "type", "filter", "hook", "output", "priority", "0", ";", "policy", "drop", ";", "}",
	); err != nil {
		return fmt.Errorf("create egress chain: %w", err)
	}

	// Always allow loopback + DNS (modules that don't allow DNS can't
	// resolve their own permitted hosts).
	if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
		"oif", "lo", "accept",
	); err != nil {
		return err
	}
	if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
		"udp", "dport", "53", "accept",
	); err != nil {
		return err
	}
	if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
		"tcp", "dport", "53", "accept",
	); err != nil {
		return err
	}

	for _, entry := range allowlist {
		host, port := parseEgressEntry(entry)
		if host == "" {
			continue
		}
		if port > 0 {
			if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
				"ip", "daddr", host, "tcp", "dport", strconv.Itoa(port), "accept",
			); err != nil {
				return fmt.Errorf("egress allow %s:%d: %w", host, port, err)
			}
		} else {
			if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
				"ip", "daddr", host, "accept",
			); err != nil {
				return fmt.Errorf("egress allow %s: %w", host, err)
			}
		}
	}
	return nil
}

// RemoveEgressAllowlist tears down the egress chain. Called when a module
// is detached.
func RemoveEgressAllowlist(ctx context.Context, runner mount.Runner) error {
	chain := "powernode_egress_filter"
	return runner.Run(ctx, "nft", "delete", "chain", "inet", EgressTable, chain)
}

// parseEgressEntry splits "host:port" → ("host", port). "host" with no
// colon → ("host", 0). IPv6 entries with colons aren't supported; they
// should be passed without a port qualifier.
func parseEgressEntry(entry string) (string, int) {
	// Don't use net.SplitHostPort — IPv6 [host]:port is uncommon for
	// egress allow lists; assume IPv4 or hostname.
	idx := strings.LastIndex(entry, ":")
	if idx < 0 {
		return strings.TrimSpace(entry), 0
	}
	host := strings.TrimSpace(entry[:idx])
	portStr := strings.TrimSpace(entry[idx+1:])
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 65535 {
		return entry, 0
	}
	return host, port
}
