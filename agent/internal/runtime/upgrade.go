package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/systemd"
)

// moduleUpgrade pairs a version bump's OLD (currently-attached) and NEW
// (freshly-desired) mount.Module entries for the SAME module ID — see
// RunOnce's own partition, built right after mount.Reconcile, which keeps
// both halves out of the ordinary detach/attach/reattach loops entirely
// (round 9, replacing the detach-before-attach mitigation stack, rounds
// 5-7, with an in-place upgrade).
type moduleUpgrade struct {
	old mount.Module
	new mount.Module
}

// upgradeModule performs an IN-PLACE upgrade of a single module from
// old.Digest to new.Digest. THE HARD INVARIANT this exists to uphold:
// never leave a previously-running module stopped. Steps run STRICTLY in
// order; any failure through step 4 returns immediately, leaving the old
// digest's process fully in charge and current.AttachedModules untouched:
//
//  1. mountModuleArtifact(new) — pull/verify/mount the new digest's blob.
//  2. applyModuleSecurityPolicy(new), the REAL writers — MAC load +
//     capability/seccomp/userns drop-ins for the NEW digest's policy.
//  3. hotReconcileIfNeeded(new) — materialize the new digest's files onto
//     the live root.
//  4. attachModuleServicesOpts(new, restartChanged: true) — write-if-
//     changed unit files, daemon-reload, restart-if-active.
//     UNCONDITIONAL restartChanged (A2, review round 9): unlike an
//     ordinary manifest-only reattach (attachModuleServices, which fences
//     a restart on a self-hosted node — see that function's own doc), a
//     version bump genuinely needs the new binary running, and the
//     detach-before-attach path this replaces ALSO restarted a
//     self-hosted node's own rails/postgres via its own stop+start cycle.
//     This is the ONLY call site that bypasses the self-host restart
//     fence; every other caller of attachModuleServices is unchanged.
//
// Steps 2-4 write onto unit names and paths SHARED with the old digest
// (a bump never renames its own unit names by ID+service — only a
// declared service rename does, handled by step 5 below) while the OLD
// process keeps running. A failure at step 3 or 4, after step 2 already
// wrote the new digest's drop-ins, leaves the OLD process running under
// the NEW digest's confinement files (A1, review round 9) —
// reapplyOldPolicyBestEffort restores them; see its own doc for exactly
// what is and is not guaranteed.
//
// Only once ALL FOUR steps succeed does anything IRREVERSIBLE happen:
//
//  5. Delta-stop: units the OLD digest owned (oldMod.Units, falling back
//     to oldMf.UnitNames() for a pre-round-9 entry) that the NEW
//     manifest no longer names are stopped, their unit file AND their
//     systemd drop-in ".d" directory removed (point 11, review round 9 —
//     a real departure must RemoveAll the ".d" dir, not just the unit
//     file, or a stale seccomp/capability/userns drop-in survives under a
//     unit name a LATER, unrelated module could reuse), then
//     daemon-reload.
//  6. Unmount the OLD erofs blob (behind unmountWouldStripLiveRoot, the
//     SAME fence detachModule itself uses).
//  7. Replace current.AttachedModules' entry for this module ID (never
//     append — exactly one entry per ID) and write the re-attach stamp.
//
// A3 (review round 9), the DOCUMENTED RESIDUAL RISK: if step 4's systemd
// job succeeds but the new binary itself then crashes, the module is
// down. This is inherent to any in-place upgrade (by the time anything
// could notice, the old process is already gone) and was already true
// under detach-before-attach — no rollback is attempted for it.
// current.AttachedModules is replaced (step 7) only after step 4 reports
// success, and any earlier failure surfaces via noteUnconverged exactly
// like an ordinary attach failure.
func (r *Reconciler) upgradeModule(ctx context.Context, current *mount.State, u moduleUpgrade, newMf, oldMf *manifest.Manifest, outgoingPaths map[string]bool, desiredForLayers mount.ModuleStack, stateWasEmpty bool) {
	old, newMod := u.old, u.new

	// Step 1: pull/verify/mount the new digest's artifact.
	if err := r.mountModuleArtifact(ctx, newMod); err != nil {
		r.noteUnconverged("reconciler:upgrade_artifact", newMod.ID, fmt.Errorf("module %s: %w", newMod.ID, err))
		return // nothing written yet — old fully untouched.
	}

	// Step 2: apply the NEW digest's security policy for real.
	r.securityPolicyAttemptedUnits = append(r.securityPolicyAttemptedUnits, newMf.UnitNames()...)
	failedUnits, err := r.applyModuleSecurityPolicy(ctx, newMod, newMf)
	if err != nil {
		r.noteUnconverged("reconciler:upgrade_policy", newMod.ID, fmt.Errorf("module %s: %w", newMod.ID, err))
		// decideModuleSecurityPolicy's OWN refusals (unapproved privileged,
		// invalid policy, an Apply failure) never reach a per-unit drop-in
		// write in that case — nothing was written onto the old digest's
		// shared paths, so there is nothing to recover here.
		return
	}
	if len(failedUnits) > 0 {
		r.recordSecurityFailClosed(failedUnits)
		r.noteUnconverged("reconciler:upgrade_policy_dropin", newMod.ID,
			fmt.Errorf("module %s: security drop-in write failed for unit(s) %v", newMod.ID, failedUnits))
		// applyModuleSecurityDropIns tries EVERY unit even after one
		// fails, so some of the new digest's drop-ins may already be on
		// disk for units that share a name with the old digest's — restore
		// them.
		r.reapplyOldPolicyBestEffort(ctx, old, oldMf, newMod.ID)
		return
	}

	// Step 3: materialize the new digest's files onto the live root.
	if r.hotReconcileIfNeeded(newMod, newMf, stateWasEmpty, outgoingPaths, desiredForLayers) {
		r.noteUnconverged("reconciler:upgrade_hotreconcile", newMod.ID, fmt.Errorf("module %s: materialization refused", newMod.ID))
		// ON DISK RIGHT NOW: the new digest's security drop-ins (step 2
		// succeeded) but NOT its file content — hotReconcileIfNeeded's own
		// refusal means the new tree was never copied onto the live root.
		// This is SAFE for the still-running OLD process (it never reads
		// the new tree; its own files are untouched) but UNSAFE for the
		// drop-ins, which now describe confinement for a module whose
		// running process is still the OLD binary. Restore them.
		r.reapplyOldPolicyBestEffort(ctx, old, oldMf, newMod.ID)
		return
	}

	// Step 4: write the new digest's unit files and restart if the body
	// changed — UNCONDITIONAL restartChanged, see this function's own doc.
	if err := r.attachModuleServicesOpts(ctx, newMod, newMf, true); err != nil {
		r.noteUnconverged("reconciler:upgrade_attach_services", newMod.ID, fmt.Errorf("module %s: %w", newMod.ID, err))
		// ON DISK RIGHT NOW: the new digest's security drop-ins AND file
		// content (step 3 succeeded) — but the unit body write and/or the
		// restart itself failed. Per A3 this may mean the old process is
		// ALREADY GONE (a documented residual risk this function does not
		// recover from — see the doc above). Re-applying the OLD policy
		// (drop-ins) is still correct and best-effort regardless: it
		// cannot undo a process that already stopped, but it also cannot
		// make anything worse.
		r.reapplyOldPolicyBestEffort(ctx, old, oldMf, newMod.ID)
		return
	}
	r.recordSecurityFailClosedRecovered(newMf.UnitNames())

	// Every step through the new digest's own attach has now succeeded —
	// proceed to the IRREVERSIBLE cutover.

	// Step 5: delta-stop units the old digest owned that the new manifest
	// no longer names (a renamed or removed service).
	r.stopDepartingUnits(ctx, old.ID, oldUnitNames(old, oldMf), newMf.UnitNames())

	// Step 6: unmount the OLD erofs blob.
	if skip, why := r.unmountWouldStripLiveRoot(old); skip {
		r.cfg.OnError("reconciler:unmount_skipped", fmt.Errorf("module %s: leaving erofs mounted — %s", old.ID, why))
	} else if err := mount.UnmountModule(ctx, r.cfg.MountRunner, r.cfg.Layout, old.Digest); err != nil {
		r.cfg.OnError("reconciler:unmount_module", fmt.Errorf("module %s: %w", old.ID, err))
	}

	// Step 7: replace the AttachedModules entry by ID (never append —
	// there must only ever be one entry per module ID), and write the
	// re-attach stamp.
	newMod.Units = newMf.UnitNames()
	replaced := false
	for i, m := range current.AttachedModules {
		if m.ID == newMod.ID {
			current.AttachedModules[i] = newMod
			replaced = true
			break
		}
	}
	if !replaced {
		current.AttachedModules = append(current.AttachedModules, newMod)
	}
	current.LastAttachedManifestHashes[newMod.ID] = r.attachStamp(newMod.ID, newMf)
}

// oldUnitNames resolves the unit names the OLD digest owned: old.Units
// when the entry was written by a round-9-or-later agent, falling back to
// oldMf.UnitNames() for an entry attached by an older build (oldMf itself
// comes from previousManifests — see upgradeModule's caller in RunOnce).
// Neither being available (a pre-round-9 entry whose manifest also failed
// to survive in the cache) means no delta-stop can be computed at all —
// logged, not guessed: guessing wrong in either direction is worse than
// declining (stopping a unit that's still wanted, or leaving a genuinely
// departed one running forever).
func oldUnitNames(old mount.Module, oldMf *manifest.Manifest) []string {
	if len(old.Units) > 0 {
		return old.Units
	}
	if oldMf != nil {
		return oldMf.UnitNames()
	}
	return nil
}

// stopDepartingUnits stops, and removes the unit file and drop-in
// directory for, every unit name in oldUnits that newUnits no longer
// names (point 11, review round 9: a real departure must RemoveAll the
// unit's ".d" directory, not just its unit file — otherwise a stale
// seccomp/capability/userns drop-in survives under a unit name a LATER,
// unrelated module could reuse).
func (r *Reconciler) stopDepartingUnits(ctx context.Context, moduleID string, oldUnits, newUnits []string) {
	if len(oldUnits) == 0 {
		return
	}
	keep := make(map[string]bool, len(newUnits))
	for _, u := range newUnits {
		keep[u] = true
	}
	departed := make([]string, 0)
	for _, u := range oldUnits {
		if !keep[u] {
			departed = append(departed, u)
		}
	}
	if len(departed) == 0 {
		return
	}
	for _, unit := range departed {
		if err := systemd.Action(ctx, r.cfg.MountRunner, unit, systemd.Stop); err != nil {
			r.cfg.OnError("reconciler:upgrade_delta_stop", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
		}
		_ = os.Remove(filepath.Join(lifecycle.UnitDir(), unit))
		_ = os.RemoveAll(filepath.Join(lifecycle.UnitDir(), unit+".d"))
	}
	if err := r.cfg.MountRunner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		r.cfg.OnError("reconciler:upgrade_delta_stop_daemon_reload", fmt.Errorf("module %s: %w", moduleID, err))
	}
}

// reapplyOldPolicyBestEffort restores the OLD digest's security drop-ins
// after a failure partway through upgradeModule has already written the
// NEW digest's (A1, review round 9). Best-effort and NEVER stops or
// restarts anything — the old process is still running throughout this
// function's entire body, and touching it here would turn a confinement-
// content bug into an availability one. Relies on writeDropInFile's own
// skip-if-identical property (L3(c), review round 7) to succeed even on a
// disk that is out of space for a NEW write: re-applying content that is
// already correct needs no new blocks.
//
// KNOWN LIMITATION, documented rather than silently accepted (per A1's own
// instruction): oldMf comes from the caller's previousManifests snapshot —
// the mutable per-module-ID manifest cache, captured at the top of THIS
// tick before this tick's own fetch loop overwrote it. On the FIRST
// upgrade attempt for a given old/new digest pair this is correct (the
// cache reflects whatever was last successfully fetched, and — since the
// old digest is what's actually attached — that fetch is the old
// digest's own). On a SECOND OR LATER consecutive failed attempt for the
// SAME pair, the PREVIOUS tick's own fetch of the new digest already
// overwrote that cache entry — previousManifests would then hold the NEW
// digest's content, not the old, and this re-apply degrades to a no-op
// (re-writing the new policy again) rather than a genuine restore. This is
// the SAME class of defect L1 (review round 7) fixed for the removed
// rollback path via a digest-keyed snapshot store; round 9 removed that
// store in favour of the lighter Units[] name list (point 3), which can
// answer "what were old's unit NAMES" but not "what was old's policy
// CONTENT" on a second attempt. Flagged to the driver as an open question
// rather than silently resolved.
func (r *Reconciler) reapplyOldPolicyBestEffort(ctx context.Context, old mount.Module, oldMf *manifest.Manifest, moduleIDForLog string) {
	if oldMf == nil {
		r.cfg.OnError("reconciler:upgrade_reapply_no_manifest",
			fmt.Errorf("module %s: no cached manifest for the old digest %s survived to re-apply its policy — the old process may be running under the NEW digest's confinement", moduleIDForLog, old.Digest))
		return
	}
	if _, err := r.applyModuleSecurityPolicy(ctx, old, oldMf); err != nil {
		r.cfg.OnError("reconciler:upgrade_reapply_failed",
			fmt.Errorf("module %s: re-applying the old digest %s's policy ALSO failed: %w", moduleIDForLog, old.Digest, err))
	}
}
