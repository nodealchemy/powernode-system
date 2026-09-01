package storage

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// ExportsDir is where we materialize per-account NFS exports. One file
// per account keeps blast radius low — bad edit in one tenant doesn't
// affect another's clients.
//
// A var rather than a const ONLY as a test seam (see SystemdUnitDir).
var ExportsDir = "/etc/exports.d"

// ApplyExports renders an exports file for one storage and re-runs
// exportfs -ra so the kernel picks it up. Caller-side has already
// taken the per-storage advisory lock — concurrent writes are safe
// from the platform side but this function does not lock locally.
func ApplyExports(ctx context.Context, runner mount.Runner, task *ExportsApplyTask) error {
	// The single validation seam for storage.exports.apply. Nothing else binds
	// this task to a share — the export path, the peer address and the options
	// are all payload-chosen. See validate.go.
	if err := task.Validate(); err != nil {
		return err
	}

	if err := os.MkdirAll(ExportsDir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", ExportsDir, err)
	}

	path := filepath.Join(ExportsDir, fmt.Sprintf("powernode-%s-%s.exports", task.AccountID, task.StorageID))
	content := renderExports(task)

	if task.Action == "revoke" && len(task.Entries) == 0 {
		// Remove the file entirely on revoke-with-no-entries.
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove exports file: %w", err)
		}
	} else {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return fmt.Errorf("write exports file: %w", err)
		}
	}

	return runner.Run(ctx, "exportfs", "-ra")
}

func renderExports(task *ExportsApplyTask) string {
	var lines []string
	lines = append(lines, fmt.Sprintf("# Powernode-managed exports for storage %s (shape=%s)", task.StorageID, task.DeploymentShape))
	lines = append(lines, fmt.Sprintf("# Account %s — DO NOT EDIT MANUALLY", task.AccountID))

	// Sort entries by peer IP for deterministic diffs.
	entries := make([]ExportsEntry, len(task.Entries))
	copy(entries, task.Entries)
	sort.Slice(entries, func(i, j int) bool { return entries[i].PeerIP < entries[j].PeerIP })

	for _, e := range entries {
		opts := strings.Join(e.Options, ",")
		if e.UID > 0 {
			opts += fmt.Sprintf(",anonuid=%d,anongid=%d", e.UID, e.GID)
		}
		// DEFECT, pre-existing and deliberately NOT fixed here: PeerIP already
		// carries a prefix length. Sdwan::PrefixAllocator.compose_address_128
		// composes "<addr>/128" and it reaches this payload unmodified via
		// Peer#assigned_address -> System::Storage::CredentialIssuer, so this
		// renders "<addr>/128/128". Every test fixture used a bare address no
		// producer emits, which is why it has never been visible. Fixing it
		// changes what is written to /etc/exports on every node and belongs in
		// its own change with its own verification — see the peer_ip note on
		// taskguard.PeerAddress, which is why that rule accepts the CIDR form.
		lines = append(lines, fmt.Sprintf("%s %s/128(%s)", task.ExportPath, e.PeerIP, opts))
	}
	return strings.Join(lines, "\n") + "\n"
}
