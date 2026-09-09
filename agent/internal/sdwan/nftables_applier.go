// nftables_applier.go — atomic apply of the per-network firewall ruleset
// the platform's Sdwan::FirewallCompiler emits.
//
// Design contract (matches the Ruby side):
//   - One nft table per Powernode install: `inet powernode_sdwan`. Distinct
//     from the egress applier's `inet powernode_module_egress` so they
//     can coexist without rule-collision risk.
//   - One chain per network: `sdwan_<8-char-net-id>`. Cross-tenant
//     isolation comes from the kernel routing path (one wg interface per
//     network) — nft is purely intra-network policy.
//   - Apply is atomic via `nft -f <tempfile>`. The platform's emitted
//     script does its own `flush chain` before re-adding rules, so
//     repeated applies converge to the desired state.
//
// Slice 2 of the SDWAN plan.

package sdwan

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

// NftablesApplier is the data-plane API for SDWAN firewall rules. The
// production agent uses ShellNftablesApplier (shells to `nft -f`); tests
// inject a NoopNftablesApplier.
type NftablesApplier interface {
	ApplyRuleset(ctx context.Context, networkID string, fw *FirewallConf) error
	RemoveChain(ctx context.Context, networkID string, fw *FirewallConf) error
	// ListChains reports the chains that actually exist in the table, which is
	// what lets the manager reap orphans by comparing ACTUAL against DESIRED
	// instead of deriving a chain name from an interface name — the two
	// suffixes differ and never mapped (IMP-01a07d31). Both chain families
	// (filter `sdwan_*` and nat `sdwan_nat_*`) share one table, so one lister
	// answers for both.
	ListChains(ctx context.Context, table string) ([]string, error)
}

// ShellNftablesApplier writes the ruleset to a temp file and runs
// `nft -f`. The temp file is mode 0600 (no secrets here, but it's good
// hygiene) and is removed after apply, regardless of outcome.
type ShellNftablesApplier struct {
	NftPath string // override for tests; defaults to "nft"
}

func NewShellNftablesApplier() *ShellNftablesApplier {
	return &ShellNftablesApplier{NftPath: "nft"}
}

func (a *ShellNftablesApplier) nft() string {
	if a.NftPath != "" {
		return a.NftPath
	}
	return "nft"
}

// ApplyRuleset writes fw.Ruleset to a temp file and runs `nft -f`. The
// platform's emitted script handles its own table/chain creation +
// flush-then-add for atomicity, so this function is a thin shim.
func (a *ShellNftablesApplier) ApplyRuleset(ctx context.Context, networkID string, fw *FirewallConf) error {
	if fw == nil {
		return errors.New("ApplyRuleset: nil firewall config")
	}
	if fw.Ruleset == "" {
		// Compiler returned no script — typically transient during network
		// creation before any rule rows exist. Treat as no-op so we don't
		// flap the chain.
		return nil
	}

	f, err := os.CreateTemp("", fmt.Sprintf("sdwan-fw-%s-*.nft", networkID[:8]))
	if err != nil {
		return fmt.Errorf("create nft tempfile: %w", err)
	}
	tmpPath := f.Name()
	defer os.Remove(tmpPath)

	if _, err := f.WriteString(fw.Ruleset); err != nil {
		f.Close()
		return fmt.Errorf("write nft tempfile: %w", err)
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return fmt.Errorf("chmod nft tempfile: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close nft tempfile: %w", err)
	}

	// `nft -f path` runs the entire script as a single transaction. Any
	// syntax error or kernel rejection rolls back — no partial state.
	if err := run(ctx, a.nft(), "-f", tmpPath); err != nil {
		return fmt.Errorf("nft -f %s (%s): %w", tmpPath, networkID, err)
	}
	return nil
}

// RemoveChain tears down the network's chain on detach. Best-effort:
// "no such chain" is treated as success.
func (a *ShellNftablesApplier) RemoveChain(ctx context.Context, networkID string, fw *FirewallConf) error {
	if fw == nil || fw.Table == "" || fw.Chain == "" {
		return nil
	}
	// `delete chain` errors with "Object does not exist" when missing —
	// swallow that case so we don't error on already-gone chains.
	_ = run(ctx, a.nft(), "delete", "chain", "inet", fw.Table, fw.Chain)
	return nil
}

// nftListing is the slice of `nft -j list table ...` this file reads. nft
// emits one array entry per object; we want the chain names and nothing else,
// so every other key decodes to a zero value and is ignored.
type nftListing struct {
	Nftables []struct {
		Chain *struct {
			Name  string `json:"name"`
			Table string `json:"table"`
		} `json:"chain"`
	} `json:"nftables"`
}

// ListChains returns the chain names present in `inet <table>`.
//
// A missing table is NOT an error: `nft` exits nonzero for it, and on a host
// that has never applied an SDWAN ruleset there is simply nothing to reap.
// Any other failure IS returned, so the caller skips the reap rather than
// treating "I could not look" as "there is nothing there" — reaping against
// an empty listing would be a no-op, but a caller that inverted the
// comparison would delete every live chain.
func (a *ShellNftablesApplier) ListChains(ctx context.Context, table string) ([]string, error) {
	if table == "" {
		return nil, errors.New("ListChains: empty table")
	}
	out, err := capture(ctx, a.nft(), "-j", "list", "table", "inet", table)
	if err != nil {
		if strings.TrimSpace(out) == "" {
			return nil, nil
		}
		return nil, fmt.Errorf("nft -j list table inet %s: %w", table, err)
	}

	var listing nftListing
	if err := json.Unmarshal([]byte(out), &listing); err != nil {
		return nil, fmt.Errorf("parse nft listing for %s: %w", table, err)
	}
	names := make([]string, 0, len(listing.Nftables))
	for _, entry := range listing.Nftables {
		if entry.Chain != nil && entry.Chain.Name != "" {
			names = append(names, entry.Chain.Name)
		}
	}
	return names, nil
}

// NoopNftablesApplier is the test-side applier — captures calls without
// touching the kernel. Lives in production code so the Manager has a
// safe default when shell-based applier is unavailable (e.g., on a
// non-Linux dev box).
type NoopNftablesApplier struct {
	Applies  []*FirewallConf
	Removals []string
	// Chains is what ListChains reports back; RemovedChains records the reap
	// by chain NAME, which is the thing IMP-01a07d31 was getting wrong.
	Chains        []string
	RemovedChains []string
}

func (n *NoopNftablesApplier) ApplyRuleset(_ context.Context, _ string, fw *FirewallConf) error {
	n.Applies = append(n.Applies, fw)
	return nil
}

func (n *NoopNftablesApplier) RemoveChain(_ context.Context, networkID string, fw *FirewallConf) error {
	n.Removals = append(n.Removals, networkID)
	if fw != nil {
		n.RemovedChains = append(n.RemovedChains, fw.Chain)
	}
	return nil
}

func (n *NoopNftablesApplier) ListChains(_ context.Context, _ string) ([]string, error) {
	return n.Chains, nil
}
