// nat_applier.go — slice 7b: atomic apply of the per-network nat
// chain (`sdwan_nat_<8>`) inside the shared `inet powernode_sdwan`
// table. Mirrors nftables_applier.go's idempotent pattern; same
// table coexists with the slice 2 filter chain because nft tables
// can hold multiple chains of different (type, hook, priority).
//
// Slice 7b of the SDWAN plan.

package sdwan

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
)

// NatApplier abstracts the per-network nat-chain apply so the manager
// is testable without `nft` available.
type NatApplier interface {
	ApplyRuleset(ctx context.Context, networkID string, nat *NatConf) error
	RemoveChain(ctx context.Context, networkID string, nat *NatConf) error
}

// ShellNatApplier shells out to `nft -f` — same install footprint as
// the slice 2 firewall applier (nft is already shipped in the
// sdwan-overlay module).
type ShellNatApplier struct {
	NftPath string // override for tests; defaults to "nft"
}

func NewShellNatApplier() *ShellNatApplier {
	return &ShellNatApplier{}
}

func (a *ShellNatApplier) nft() string {
	if a.NftPath != "" {
		return a.NftPath
	}
	return "nft"
}

// ApplyRuleset writes nat.Ruleset to a 0600 tempfile and runs `nft -f`.
// Empty Ruleset means "no port mappings" — we tear down the chain
// instead of skipping, so that a previously-installed chain doesn't
// linger after the operator deletes the last mapping.
func (a *ShellNatApplier) ApplyRuleset(ctx context.Context, networkID string, nat *NatConf) error {
	if nat == nil {
		return errors.New("ApplyRuleset: nil nat config")
	}
	if nat.Ruleset == "" {
		// Compiler returned no script (zero mappings). Tear down to
		// converge — leaving the chain present with stale rules from a
		// previous tick would be a silent footgun.
		return a.RemoveChain(ctx, networkID, nat)
	}

	prefix := networkID
	if len(prefix) > 8 {
		prefix = prefix[:8]
	}
	f, err := os.CreateTemp("", fmt.Sprintf("sdwan-nat-%s-*.nft", prefix))
	if err != nil {
		return fmt.Errorf("create nft tempfile: %w", err)
	}
	tmpPath := f.Name()
	defer os.Remove(tmpPath)

	if _, err := f.WriteString(nat.Ruleset); err != nil {
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

	// nft's parser handles `add chain ...` idempotently when the chain
	// already exists; for the simple "table { chain { ... } }" form the
	// compiler emits we need a `delete chain` first to flush stale
	// rules. We do that via a sister `nft delete chain` invocation
	// before applying — failures are tolerated (the chain may not exist
	// on first apply).
	a.deleteChainBestEffort(ctx, nat)

	cmd := exec.CommandContext(ctx, a.nft(), "-f", tmpPath)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("nft -f: %w; stderr=%s", err, stderr.String())
	}
	return nil
}

// RemoveChain tears down the nat chain — used when the operator
// deletes the last port mapping or removes the network entirely.
func (a *ShellNatApplier) RemoveChain(ctx context.Context, _ string, nat *NatConf) error {
	if nat == nil || nat.Table == "" || nat.Chain == "" {
		return nil
	}
	a.deleteChainBestEffort(ctx, nat)
	return nil
}

func (a *ShellNatApplier) deleteChainBestEffort(ctx context.Context, nat *NatConf) {
	cmd := exec.CommandContext(ctx, a.nft(),
		"delete", "chain", "inet", nat.Table, nat.Chain)
	// Always best-effort — if the chain doesn't exist, nft errors out;
	// we tolerate that. We capture stderr but don't surface it.
	_, _ = cmd.CombinedOutput()
}
