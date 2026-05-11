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
const ExportsDir = "/etc/exports.d"

// ApplyExports renders an exports file for one storage and re-runs
// exportfs -ra so the kernel picks it up. Caller-side has already
// taken the per-storage advisory lock — concurrent writes are safe
// from the platform side but this function does not lock locally.
func ApplyExports(ctx context.Context, runner mount.Runner, task *ExportsApplyTask) error {
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
		lines = append(lines, fmt.Sprintf("%s %s/128(%s)", task.ExportPath, e.PeerIP, opts))
	}
	return strings.Join(lines, "\n") + "\n"
}
