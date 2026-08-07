package runtime

import (
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// ClearAttachedManifestHashes forces the next reconcile to re-materialize a
// module's files (or every module's, when moduleID is empty) by dropping the
// manifest-hash stamps the reattach gate compares against.
//
// This is the repair path for a root whose files were removed underneath an
// UNCHANGED digest — the 2026-08-07 shape, where an empty artifact's hot-prune
// whiteout-deleted /usr/local/go and /usr/local/bin/gitleaks. Nothing drifts in
// that state: the digest still matches, the ServicesHash still matches, so
// RunOnce correctly concludes there is nothing to do and the existing
// sync_modules task repairs nothing. Recovery was a hand bind-mount over a root
// shell; this makes it an ordinary platform action.
//
// The module STAYS in AttachedModules. The erofs layer really is mounted — only
// the copy into the live root is being redone — and dropping the attachment
// would make the next pass treat this as a fresh attach and re-mount it.
//
// An unknown moduleID is an ERROR rather than a silent no-op: an operator who
// mistypes a slug must not be told the node was resynced when nothing was
// queued.
func (r *Reconciler) ClearAttachedManifestHashes(moduleID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	unlock, err := mount.Lock(r.cfg.StatePath)
	if err != nil {
		return fmt.Errorf("state lock: %w", err)
	}
	defer unlock()

	current, err := mount.LoadState(r.cfg.StatePath)
	if err != nil {
		return fmt.Errorf("load state: %w", err)
	}
	if current.LastAttachedManifestHashes == nil {
		current.LastAttachedManifestHashes = map[string]string{}
	}

	if moduleID == "" {
		current.LastAttachedManifestHashes = map[string]string{}
	} else {
		// Keyed on ATTACHMENT, not on the stamp's presence. A module can be
		// legitimately attached with no stamp — the budget-abort retry deletes
		// it precisely so the next pass re-materializes — and erroring there
		// would fail the repair for a node that is already queued for one.
		// Absence from AttachedModules is the real "you typed the wrong id".
		attached := false
		for _, m := range current.AttachedModules {
			if m.ID == moduleID {
				attached = true
				break
			}
		}
		if !attached {
			return fmt.Errorf("module %q is not attached on this node; nothing to resync "+
				"(expects the platform NodeModule UUID, not the module slug)", moduleID)
		}
		delete(current.LastAttachedManifestHashes, moduleID)
	}

	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		return fmt.Errorf("save state: %w", err)
	}
	return nil
}
