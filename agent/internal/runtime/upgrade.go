package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
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
// old.Digest to new.Digest.
//
// THE INVARIANT (operator-redefined, round 11, replacing round 9's
// original "never stop a unit" absolute): refusals and bookkeeping — a
// policy refusal, the identity/sudoers/egress render, a duplicate state
// entry, a stale cache, or a reporting/heartbeat path — must NEVER stop or
// restart a running unit; but a VERSION UPGRADE MAY restart units, because
// that is the only way a bump ever takes effect. If a restart fails, the
// module must auto-recover (retry, revert, or re-bump — see N2/PendingDigest
// below) and the failure must be VISIBLE to the operator (PendingDigest +
// PendingModuleDigests in the heartbeat, a persisted server-side alert —
// never silently swallowed). Steps run STRICTLY in order; any failure
// through step 4 leaves the old digest's process running (possibly
// mid-restart — see PendingDigest) and reports the failure rather than
// silently retrying forever with no visible signal:
//
//  1. mountModuleArtifact(new) — pull/verify/mount the new digest's blob.
//  2. applyModuleSecurityPolicy(new), the REAL writers — MAC load +
//     capability/seccomp/userns drop-ins for the NEW digest's policy.
//  3. hotReconcileIfNeeded(new) — materialize the new digest's files onto
//     the live root.
//  4. attachModuleServicesOpts(new, forceRestartActive: true) — write-if-
//     changed unit files, UNCONDITIONAL daemon-reload, and a FORCED
//     restart of every unit of the new manifest that is currently active
//     — regardless of whether its own rendered body happened to change
//     this pass (M1, review round 9: a digest bump whose services: block
//     is byte-identical to the old one — the common case, most bumps
//     change application code, not the unit shape — was previously only
//     `start`-ed, a no-op on an already-active unit, leaving the OLD
//     binary running under a state.json that claimed the NEW digest had
//     committed). Also (A2, review round 9) the ONLY call site that
//     bypasses the self-host restart fence: unlike an ordinary
//     manifest-only reattach (attachModuleServices, which fences a
//     restart on a self-hosted node — see that function's own doc), a
//     version bump genuinely needs the new binary running, and the
//     detach-before-attach path this replaces ALSO restarted a
//     self-hosted node's own rails/postgres via its own stop+start cycle.
//     Every other caller of attachModuleServices is unchanged.
//
// Steps 2-4 write onto unit names and paths SHARED with the old digest
// (a bump never renames its own unit names by ID+service — only a
// declared service rename does, handled by step 5 below) while the OLD
// process keeps running. A failure at step 3 or 4, after step 2 already
// wrote the new digest's drop-ins, leaves the OLD process running under
// the NEW digest's confinement files (A1, review round 9) —
// restoreDropInSnapshot restores them from a byte-exact snapshot taken
// before step 2 (R3b); see its own doc for exactly what is and is not
// guaranteed.
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

	// M7 (review round 9): resolve the old digest's unit list up front, and
	// if this entry predates round 9 (old.Units empty — an entry attached
	// before mount.Module carried the field), PERSIST the resolved
	// fallback onto the CURRENT state entry immediately, before step 1 even
	// runs. Without this, a first attempt that fails leaves the SECOND
	// attempt re-deriving the same fallback from oldMf all over again — and
	// oldMf (previousManifests) is exactly the piece R3b's snapshot below
	// no longer depends on for POLICY CONTENT, but the unit NAME list is a
	// separate, smaller fact this still resolves from the manifest cache
	// when Units is empty, so making it durable on the first attempt avoids
	// re-rolling that same dice on every later one.
	oldUnits := oldUnitNames(old, oldMf)
	if len(old.Units) == 0 && len(oldUnits) > 0 {
		old.Units = oldUnits
		for i, m := range current.AttachedModules {
			if m.ID == old.ID {
				current.AttachedModules[i].Units = oldUnits
				break
			}
		}
	}

	// Step 1: pull/verify/mount the new digest's artifact.
	if err := r.mountModuleArtifact(ctx, newMod); err != nil {
		r.noteUnconverged("reconciler:upgrade_artifact", newMod.ID, fmt.Errorf("module %s: %w", newMod.ID, err))
		return // nothing written yet — old fully untouched.
	}

	// R3b (review round 9): snapshot the ACTUAL on-disk bytes of every
	// drop-in file this attempt could touch — old's own units union the new
	// manifest's units (a renamed service's new-only unit correctly has no
	// snapshot entry with existed=true: it never existed before this
	// attempt, so "restoring" it means removing it) — taken fresh THIS
	// attempt, before step 2 writes anything. See restoreDropInSnapshot's
	// own doc for why this replaces the old manifest-re-render approach.
	dropInSnap := snapshotUnitDropIns(unionStrings(oldUnits, newMf.UnitNames()))

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
		// them from the pre-step-2 snapshot. Nothing has been restarted yet
		// (step 4 hasn't run), so every snapshot entry is eligible.
		restoreDropInSnapshot(dropInSnap, nil, r.cfg.OnError)
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
		// running process is still the OLD binary. Restore them — again,
		// nothing has restarted yet.
		restoreDropInSnapshot(dropInSnap, nil, r.cfg.OnError)
		return
	}

	// M9 (review round 9, HIGH): persist PendingDigest onto the EXISTING
	// (still old-digest) state entry and save to disk IMMEDIATELY, before
	// step 4 issues a single restart. A module can own several units, and
	// AttachServicesModeOpts keeps attempting the REST of them even after
	// one fails (its own "soft failure" continuation — see that function's
	// doc) — so a partial multi-unit restart is a real, reachable outcome:
	// one unit already running the NEW binary while a later one in the
	// SAME module fails. Without this, state.json and the heartbeat both
	// still claim old.Digest alone at that point, which by then describes
	// NEITHER unit's actual running binary. Cleared at step 7 on commit
	// (newMod, replacing this entry, carries no PendingDigest of its own).
	for i, m := range current.AttachedModules {
		if m.ID == newMod.ID {
			current.AttachedModules[i].PendingDigest = newMod.Digest
			break
		}
	}
	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		r.cfg.OnError("reconciler:upgrade_pending_save", fmt.Errorf("module %s: could not persist the pending digest %s before restarting: %w", newMod.ID, newMod.Digest, err))
	}

	// N1 (review round 11): snapshot which of the NEW manifest's units were
	// active BEFORE step 4 touches anything. A unit that was never active to
	// begin with (a credential-fetch/provisioning script that runs once and
	// exits — claude-tmux's credential unit, grok-cli, dev-cell's own
	// credential/provision units) reads "inactive" after a clean, successful
	// run exactly as it would after a crash; the settle check below only
	// ever applies to a unit this snapshot says WAS running, so a run-once
	// unit's own exit is never mistaken for a crash.
	preActive := make(map[string]bool, len(newMf.UnitNames()))
	for _, unit := range newMf.UnitNames() {
		if active, aerr := systemd.IsActive(ctx, r.cfg.MountRunner, unit); aerr == nil && active {
			preActive[unit] = true
		}
	}

	// Step 4: write the new digest's unit files and FORCE-restart every unit
	// that is currently active, regardless of whether its own body changed
	// this pass (M1, review round 9 — see lifecycle.AttachOptions.
	// ForceRestartActive's own doc for why the ordinary RestartChanged
	// decision is wrong for a digest bump specifically).
	results, err := r.attachModuleServicesOpts(ctx, newMod, newMf, true, true)
	// N6 (review round 11): every unit step 4 actually bounced onto the new
	// binary, regardless of whether the OVERALL call returned an error —
	// AttachServicesModeOpts keeps attempting units after one fails (its own
	// "soft failure" continuation), so results names each unit's own
	// outcome independently. A unit in this set must never have its
	// drop-ins reverted to the old policy by a LATER failure in this same
	// attempt: it is already running the new process.
	restartedUnits := make(map[string]bool, len(results))
	for _, res := range results {
		if res.Restarted || res.Started {
			restartedUnits[res.Unit] = true
		}
	}
	if err != nil {
		r.noteUnconverged("reconciler:upgrade_attach_services", newMod.ID, fmt.Errorf(
			"module %s: %w (PendingDigest %s left set — some units of this module may already be running the new binary; see PendingModuleDigests in the next heartbeat)", newMod.ID, err, newMod.Digest))
		// ON DISK RIGHT NOW: the new digest's security drop-ins AND file
		// content (step 3 succeeded) — but the unit body write and/or the
		// restart itself failed for AT LEAST one unit. Per A3 this may mean
		// that unit's old process is ALREADY GONE (a documented residual
		// risk this function does not recover from — see the doc above).
		// Re-applying the OLD policy (drop-ins) is still correct and
		// best-effort for every unit NOT already restarted onto the new
		// binary: it cannot undo a process that already stopped, but it
		// also cannot make anything worse — and per N6, a unit that DID
		// restart keeps the new policy it is actually running under.
		restoreDropInSnapshot(dropInSnap, restartedUnits, r.cfg.OnError)
		return
	}
	r.recordSecurityFailClosedRecovered(newMf.UnitNames())

	// N1 (review round 11), M6 (review round 9, MEDIUM): `systemctl start`/
	// `restart` succeeding proves only that ExecStart was launched — every
	// unit this codebase renders is Type=simple (lifecycle.
	// RenderUnitModeGraph), so systemd considers the unit "active" the
	// instant the process exists, with no health signal of its own. A
	// binary that crashes immediately after exec (a bad migration, a
	// config the new digest ships that the process rejects on boot) would
	// otherwise sail through step 4 as a reported success. Settle briefly,
	// then confirm every unit that WAS ACTIVE BEFORE (preActive) is STILL
	// active before anything irreversible runs.
	//
	// A unit that was NEVER active before this attempt is skipped entirely
	// — its own inactivity now is not new information (N1). For a unit
	// that WAS active and now reads inactive, a clean, expected
	// termination (Result=success — it ran its course and stopped on its
	// own) or a condition-gate skip (ConditionResult=no) is ALSO settled,
	// not a crash; only anything else refuses.
	//
	// A3 RESIDUAL, restated here rather than silently left implicit: if a
	// unit that failed here declares a start_before/requires_health
	// dependency edge (recoveryDependents, lifecycle/service.go), its
	// dependents render Requires= and may ALREADY have been stopped by
	// systemd's own propagation before this check even runs — this
	// function does not attempt to restart them; they surface as their own
	// modules' next reconcile tick finds them inactive, same as any other
	// A3 case.
	sleepForUpgradeSettle(r.cfg.UpgradeSettleWindow)
	for _, unit := range newMf.UnitNames() {
		if !preActive[unit] {
			continue
		}
		active, aerr := systemd.IsActive(ctx, r.cfg.MountRunner, unit)
		if aerr == nil && active {
			continue
		}
		result, _ := systemd.ShowProperty(ctx, r.cfg.MountRunner, unit, "Result")
		condResult, _ := systemd.ShowProperty(ctx, r.cfg.MountRunner, unit, "ConditionResult")
		if result == "success" || condResult == "no" {
			continue
		}
		r.noteUnconverged("reconciler:upgrade_settle_check", newMod.ID, fmt.Errorf(
			"module %s: unit %s did not stay active through the %s settle window after restart (is-active err=%v, Result=%q, ConditionResult=%q) — refusing to delta-stop, unmount, or commit; a dependent unit may already have stopped as a propagation of this failure (documented A3 residual)",
			newMod.ID, unit, r.cfg.UpgradeSettleWindow, aerr, result, condResult))
		restoreDropInSnapshot(dropInSnap, restartedUnits, r.cfg.OnError)
		return
	}

	// Every step through the new digest's own attach has now succeeded and
	// settled — proceed to the IRREVERSIBLE cutover.

	// Step 5: delta-stop units the old digest owned that the new manifest
	// no longer names (a renamed or removed service).
	r.stopDepartingUnits(ctx, old.ID, oldUnits, newMf.UnitNames())

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

// dropInFileNames is the fixed set of per-unit drop-in files any writer in
// this codebase creates (security/capabilities.go WriteCapabilityDropIn(At),
// mac.go writeSeccompDropInAt, userns_dropin.go writeUserNamespaceDropInAt).
// snapshotUnitDropIns/restoreDropInSnapshot only ever touch these three
// names, under a unit this upgrade's own old-or-new unit set names — never
// an arbitrary path.
var dropInFileNames = []string{"capabilities.conf", "seccomp.conf", "userns.conf"}

// dropInSnapshot captures one drop-in file's on-disk content at a point in
// time, byte-exact.
type dropInSnapshot struct {
	unit     string // the unit name this drop-in belongs to (N6, review round 11)
	dir      string // <unit>.d directory
	filename string
	existed  bool
	body     string
	// unreadable is true when the pre-attempt read failed for a reason OTHER
	// than the path genuinely not existing (permission denied, the path is a
	// directory rather than a regular file, etc). restoreDropInSnapshot
	// leaves such an entry alone entirely — treating "could not read" as
	// "did not exist" would let a restore's own cleanup step (os.Remove for
	// an existed=false entry) delete something that was NOT, in fact,
	// absent; os.Remove succeeds on an empty directory just as readily as on
	// a stray file, so an ambiguous read must never be resolved to "removable"
	// (same declining-over-guessing stance oldUnitNames' own doc takes).
	unreadable bool
}

// snapshotUnitDropIns records the CURRENT on-disk content (or absence) of
// every known drop-in file for every unit in units, read from
// security.SystemdDropInRoot() — the SAME root every real drop-in writer in
// this codebase targets.
//
// R3b (review round 9): replaces the removed reapplyOldPolicyBestEffort,
// which re-rendered the old digest's policy from oldMf (RunOnce's
// previousManifests snapshot) rather than restoring an actual byte
// snapshot. That re-render was correct on the FIRST upgrade attempt for a
// given old/new digest pair, but degraded to a no-op on a SECOND OR LATER
// consecutive failed attempt: the first attempt's own manifest fetch had
// already overwritten previousManifests' on-disk cache with the NEW
// digest's content by the time the second attempt ran, so "restoring the
// old policy" silently re-wrote the already-wrong new one instead. A byte
// snapshot taken fresh on EVERY attempt, immediately before that attempt's
// own step 2 writes anything, has no such dependency — attempt N's
// snapshot is attempt N's actual pre-write state, full stop, independent
// of what any earlier attempt fetched, wrote, or left behind.
func snapshotUnitDropIns(units []string) []dropInSnapshot {
	root := security.SystemdDropInRoot()
	snaps := make([]dropInSnapshot, 0, len(units)*len(dropInFileNames))
	for _, unit := range units {
		dir := filepath.Join(root, unit+".d")
		for _, name := range dropInFileNames {
			s := dropInSnapshot{unit: unit, dir: dir, filename: name}
			body, err := os.ReadFile(filepath.Join(dir, name))
			switch {
			case err == nil:
				s.existed = true
				s.body = string(body)
			case os.IsNotExist(err):
				// Genuinely absent — existed stays false, which is what
				// lets restoreDropInSnapshot remove a file the upgrade
				// itself creates.
			default:
				// Some OTHER read error (permission denied, the path is a
				// directory rather than a regular file, ...): we cannot
				// characterize the pre-attempt state at all. Marking this
				// unreadable rather than existed=false is load-bearing —
				// see dropInSnapshot's own doc.
				s.unreadable = true
			}
			snaps = append(snaps, s)
		}
	}
	return snaps
}

// restoreDropInSnapshot restores EXACTLY what snapshotUnitDropIns captured:
// a file that existed is rewritten to its snapshot bytes via
// security.WriteRawDropInFileForRestore — the SAME skip-if-identical,
// atomic tmp-write-then-rename path every real drop-in writer uses (L3(c),
// review round 7), so restoring content that is already correct on disk
// needs no new blocks even on a disk that is out of space for a genuinely
// NEW write. A file that did NOT exist before this attempt (the new
// policy's own step 2 created it — e.g. a seccomp.conf the old policy never
// wrote) is removed.
//
// NEVER stops or restarts anything — the old process is still running
// throughout this function's entire body, and touching it here would turn
// a confinement-content bug into an availability one.
//
// alreadyRestarted (N6, review round 11) names every unit step 4 already
// bounced onto the NEW binary before the failure this restore is reacting
// to — a partial multi-unit restart's earlier, successful units. Restoring
// THEIR drop-ins to the old policy would describe confinement for a
// process that is no longer the one running under it; entries for such a
// unit are skipped entirely, left exactly as step 2/4 last wrote them.
func restoreDropInSnapshot(snaps []dropInSnapshot, alreadyRestarted map[string]bool, onError func(stage string, err error)) {
	for _, s := range snaps {
		if s.unreadable {
			continue
		}
		if alreadyRestarted[s.unit] {
			continue
		}
		path := filepath.Join(s.dir, s.filename)
		if s.existed {
			if err := security.WriteRawDropInFileForRestore(s.dir, s.filename, s.body); err != nil {
				onError("reconciler:upgrade_reapply_failed", fmt.Errorf("restore %s: %w", path, err))
			}
			continue
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			onError("reconciler:upgrade_reapply_failed", fmt.Errorf("remove %s: %w", path, err))
		}
	}
}

// unionStrings returns the set union of a and b, preserving first-seen
// order and de-duplicating — used to build the full set of unit names
// snapshotUnitDropIns must cover (both the old digest's units and the new
// manifest's, since either side alone could miss a renamed service's
// drop-ins on one end or the other).
func unionStrings(a, b []string) []string {
	seen := make(map[string]bool, len(a)+len(b))
	out := make([]string, 0, len(a)+len(b))
	for _, list := range [][]string{a, b} {
		for _, s := range list {
			if !seen[s] {
				seen[s] = true
				out = append(out, s)
			}
		}
	}
	return out
}
