package runtime

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// This file closes the LEAVER half of the live-recompose contract.
//
// hotreconcile.go + hotprune.go make a module VERSION change fully apply to
// a live pivot root: new content copies up, dropped paths prune with
// surviving-layer resolution. But a module leaving the composition entirely
// was deliberately excluded (see captureOutgoingPaths): its units stop, its
// erofs unmounts, and its files keep being served by / until a reboot
// recomposes the union without it.
//
// The exclusion's stated reason — "removing files live would race an
// operator mid-reassignment" — is here turned into a one-tick deferral
// rather than a permanent gap:
//
//  tick T:   the leaver is detached. Its file inventory (captured while the
//            erofs was still mounted) is written as a pending-prune record
//            under /run/powernode/pending-prune/, unarmed.
//  tick T:   processPendingPrunes (later in the same RunOnce) sees the
//            unarmed record and only ARMS it.
//  tick T+1: the record is armed. If the module is still absent from the
//            desired composition, its paths run through PruneRemovedFiles —
//            the same surviving-layer resolution version bumps use — and
//            the record is consumed. If the module reappeared (assignment
//            flap, operator mid-reassignment), the record is dropped and
//            the re-attach's own sync restores anything a premature prune
//            would have taken.
//
// Records live on /run (tmpfs) on purpose: a full reboot recomposes the
// union without the leaver anyway, so losing records at reboot is correct,
// not lossy. After a soft-reboot (which preserves /run) a stale record
// prunes paths the fresh compose already excluded — every candidate
// resolves to "already gone", a no-op.

// pendingPruneRecord is one leaver awaiting its deferred prune.
type pendingPruneRecord struct {
	ModuleID string `json:"module_id"`
	Digest   string `json:"digest"`
	// Files is the root-rooted file/symlink inventory of the departed
	// module's tree, captured pre-unmount (ModuleTreePaths.Files).
	Files []string `json:"files"`
	// Protected is the module's protected_spec, carried so the deferred
	// prune honors it after the manifest may be gone from cache.
	Protected []string `json:"protected,omitempty"`
	// Armed is false when written at detach time; the first
	// processPendingPrunes pass flips it, the second executes. This is
	// what makes the deferral exactly one tick.
	Armed bool `json:"armed"`
}

// pendingPruneDir is where records live, under Layout.Root for test
// redirection (same pattern as hotReconcileIfNeeded's dstRoot).
func (r *Reconciler) pendingPruneDir() string {
	return filepath.Join(r.cfg.Layout.Root, "/run/powernode/pending-prune")
}

// captureLeaverInventories inventories every module leaving the composition
// entirely (no same-ID successor in toAttach) while its erofs is STILL
// mounted — mirroring captureOutgoingPaths, which owns the version-bump
// case. Native (pivot) root mode only: the cloud_init model remounts the
// whole union on every stack change, so leavers vanish there naturally.
func (r *Reconciler) captureLeaverInventories(toDetach, toAttach mount.ModuleStack, manifests map[string]*manifest.Manifest) []pendingPruneRecord {
	if r.cfg.DryRun || len(toDetach) == 0 {
		return nil
	}
	if pivotAwareRootMode() != lifecycle.RootModeNative {
		return nil
	}
	incoming := make(map[string]bool, len(toAttach))
	for _, m := range toAttach {
		incoming[m.ID] = true
	}
	var out []pendingPruneRecord
	for _, mod := range toDetach {
		if incoming[mod.ID] {
			continue // version bump — captureOutgoingPaths owns it
		}
		mf, ok := manifests[mod.ID]
		if !ok {
			mf, _ = manifest.LoadFromDisk(r.cfg.ManifestRoot, mod.ID)
		}
		if mf != nil && mf.RebootRequired {
			// Same contract as hotReconcileIfNeeded: the module declared
			// its files can't be safely hot-swapped, and that includes
			// hot-removal.
			r.cfg.OnError("reconciler:reboot_pending",
				fmt.Errorf("module %s left the composition but reboot_required=true; a reboot (or `powernode-agent soft-recompose --execute`) is needed to remove its files", mod.ID))
			continue
		}
		tp, err := ModuleTreePaths(r.cfg.Layout.ModuleMountPath(mod.Digest))
		if err != nil {
			// A partial inventory understates the removals — safe, but
			// prune from a partial baseline is worse than skipping. Same
			// policy as captureOutgoingPaths.
			r.cfg.OnError("reconciler:capture_leaver",
				fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		if len(tp.Files) == 0 {
			continue
		}
		files := make([]string, 0, len(tp.Files))
		for p := range tp.Files {
			files = append(files, p)
		}
		sort.Strings(files)
		rec := pendingPruneRecord{ModuleID: mod.ID, Digest: mod.Digest, Files: files}
		if mf != nil {
			rec.Protected = mf.ProtectedSpec
		}
		out = append(out, rec)
	}
	return out
}

// writePendingPrunes persists captured leaver records. Called after the
// detach loop — the inventory is already safely in memory, and writing
// after detach means a failed detach still leaves a record whose prune
// converges the live root toward the desired (leaver-free) composition.
// A re-leave of the same module overwrites (and so re-defers) its record.
func (r *Reconciler) writePendingPrunes(records []pendingPruneRecord) {
	if len(records) == 0 {
		return
	}
	dir := r.pendingPruneDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		r.cfg.OnError("reconciler:pending_prune", fmt.Errorf("mkdir %s: %w", dir, err))
		return
	}
	for _, rec := range records {
		path := filepath.Join(dir, rec.ModuleID+".json")
		if err := fsutil.AtomicWriteJSON(path, rec, 0o644); err != nil {
			r.cfg.OnError("reconciler:pending_prune",
				fmt.Errorf("write record for module %s: %w", rec.ModuleID, err))
		}
	}
}

// processPendingPrunes walks the pending-prune records: arms unarmed ones,
// executes armed ones whose module is still absent from desired, drops
// ones whose module reappeared. Runs after the attach loops so every
// desired module's tree is mounted and recorded before any resolution.
func (r *Reconciler) processPendingPrunes(desired mount.ModuleStack) {
	if r.cfg.DryRun {
		return
	}
	if pivotAwareRootMode() != lifecycle.RootModeNative {
		return
	}
	dir := r.pendingPruneDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			r.cfg.OnError("reconciler:pending_prune", err)
		}
		return
	}
	if len(entries) == 0 {
		return
	}

	desiredIDs := make(map[string]bool, len(desired))
	for _, m := range desired {
		desiredIDs[m.ID] = true
		if _, statErr := os.Stat(r.cfg.Layout.ModuleMountPath(m.Digest)); statErr != nil {
			// A missing surviving layer would make every path it provides
			// look sole-owned and turn restores into removals. Defer the
			// whole pass to a tick where the full desired stack is mounted.
			return
		}
	}

	root := filepath.Join(r.cfg.Layout.Root, "/")
	for _, e := range entries {
		path := filepath.Join(dir, e.Name())
		data, rerr := os.ReadFile(path)
		if rerr != nil {
			r.cfg.OnError("reconciler:pending_prune", fmt.Errorf("read %s: %w", path, rerr))
			continue
		}
		var rec pendingPruneRecord
		if uerr := json.Unmarshal(data, &rec); uerr != nil {
			r.cfg.OnError("reconciler:pending_prune", fmt.Errorf("parse %s: %w", path, uerr))
			_ = os.Remove(path) // unparseable — will never become actionable
			continue
		}
		if desiredIDs[rec.ModuleID] {
			// Reassignment flap: the module came back before the prune
			// fired. Its re-attach sync is the authority now.
			_ = os.Remove(path)
			continue
		}
		if !rec.Armed {
			rec.Armed = true
			if werr := fsutil.AtomicWriteJSON(path, rec, 0o644); werr != nil {
				r.cfg.OnError("reconciler:pending_prune",
					fmt.Errorf("arm record for module %s: %w", rec.ModuleID, werr))
			}
			continue
		}

		oldPaths := make(map[string]bool, len(rec.Files))
		for _, f := range rec.Files {
			oldPaths[f] = true
		}
		res, perr := PruneRemovedFiles(PruneOptions{
			OldPaths: oldPaths,
			// No successor — every inventoried path is a candidate.
			NewErofsDir:     "",
			DstRoot:         root,
			SurvivingLayers: r.survivingLayerDirs(desired, rec.ModuleID),
			Protected:       rec.Protected,
		})
		if perr != nil {
			r.cfg.OnError("reconciler:leaver_prune",
				fmt.Errorf("module %s: %w", rec.ModuleID, perr))
		}
		if res.Restored > 0 {
			r.cfg.OnError("reconciler:hot_prune_contested",
				fmt.Errorf("module %s left the composition but %d of its path(s) are also provided by a surviving module and were restored from it", rec.ModuleID, res.Restored))
		}
		// Consumed either way: per-entry prune failures are surfaced above,
		// and a reboot converges anything left behind — retrying a stuck
		// entry every tick forever would only spam OnError.
		_ = os.Remove(path)
	}
}
