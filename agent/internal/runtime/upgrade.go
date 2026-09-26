package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/systemd"
)

// nowForUpgradeBackoff is N2's per-digest backoff clock (review round 11),
// indirected like sleepForUpgradeSettle so tests can control it without a
// real wait.
var nowForUpgradeBackoff = time.Now

// upgradeBackoffFor returns how long a retry of the SAME pending digest
// must wait, given it has already been attempted `attempts` times. A
// crash-looping binary must never be force-restarted on every single
// reconcile tick forever, but must also never be abandoned outright — this
// grows the wait geometrically and caps it, rather than giving up.
func upgradeBackoffFor(attempts int) time.Duration {
	if attempts <= 0 {
		return 0
	}
	const (
		base    = 10 * time.Second
		maxWait = 5 * time.Minute
	)
	if attempts > 6 { // 10s * 2^5 = 320s already exceeds maxWait
		attempts = 6
	}
	wait := base * time.Duration(uint64(1)<<uint(attempts-1))
	if wait > maxWait {
		wait = maxWait
	}
	return wait
}

// backoffAllows is N2's shared backoff GATE (review round 11, extended to
// the revert path in O3, review round 12): whether an attempt against the
// SAME pending target may proceed now, given it has already been attempted
// `attempts` times, most recently at `lastAttemptUnix`. The very first
// attempt and its first retry (attempts < 2) always proceed — matching M2's
// own retry-after-failure test, which expects an immediate next-tick retry
// with no elapsed time; from the second retry on, upgradeBackoffFor's
// geometric wait must have elapsed. O3: this was previously inlined ONLY
// in upgradeModule's own top-of-function gate — the N2 revert path
// (reconcile.go) called its own force-restart with NO backoff at all,
// retrying a failing forced restart on EVERY tick forever.
//
// O8(b), review round 12: a NEGATIVE elapsed (the wall clock moved
// backwards since lastAttemptUnix — an NTP correction, a suspended VM
// resuming, a clock the operator set back) is treated as ELIGIBLE, not as
// "no time has passed yet". The alternative — comparing a negative elapsed
// against a positive wait and reading it as "not enough time has passed" —
// would let a single backwards clock jump wedge a retry indefinitely
// (elapsed never legitimately "catches up" past a wait computed from a
// LastAttemptUnix now in the apparent future), which is a worse failure
// mode than retrying slightly early.
func backoffAllows(attempts int, lastAttemptUnix int64) (allowed bool, wait, elapsed time.Duration) {
	if attempts < 2 {
		return true, 0, 0
	}
	wait = upgradeBackoffFor(attempts)
	elapsed = nowForUpgradeBackoff().Sub(time.Unix(lastAttemptUnix, 0))
	if elapsed < 0 {
		return true, wait, elapsed
	}
	return elapsed >= wait, wait, elapsed
}

// recordPendingDigestAttempt bumps moduleID's PendingDigestAttempts and
// PendingDigestLastAttemptUnix for its CURRENT pending target and persists
// the change. P7 (review round 13, LOW): steps 1-3's own refusals (artifact
// pull/mount, security policy, hot-reconcile materialization) never counted
// as an attempt against backoffAllows's gate — only step 4's own restart
// attempt did (the PendingDigestAttempts++ a little further down, right
// before the restart it precedes). With Attempts staying 0 forever across
// repeated step 1-3 refusals, backoffAllows(0, ...) is always immediately
// eligible (attempts < 2 always proceeds) — a persistently failing artifact
// pull, an unapproved-privileged policy refusal, or a materialization that
// never fits the scratch budget was re-attempted on EVERY single reconcile
// tick, forever, instead of backing off like a step-4 failure does. Called
// from each of steps 1-3's own refusal branches, immediately before their
// early return — never touches PendingDigestUnitsTouched or
// PendingIntroducedUnits, since a step 1-3 refusal never reaches a unit.
func (r *Reconciler) recordPendingDigestAttempt(current *mount.State, moduleID string) {
	for i, m := range current.AttachedModules {
		if m.ID == moduleID {
			current.AttachedModules[i].PendingDigestAttempts++
			current.AttachedModules[i].PendingDigestLastAttemptUnix = nowForUpgradeBackoff().Unix()
			// Q3 (review round 14, LOW): ALSO record that steps 1-3 genuinely
			// refused this target — see PendingDigestActuallyRefused's own
			// doc. Every call site of this function IS one of steps 1-3's
			// own refusal points, so this belongs here rather than
			// duplicated at each call site.
			current.AttachedModules[i].PendingDigestActuallyRefused = true
			break
		}
	}
	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		r.cfg.OnError("reconciler:upgrade_pending_save", fmt.Errorf("module %s: could not persist the refused attempt's backoff count: %w", moduleID, err))
	}
}

// settleFailure records why a unit was judged NOT settled after step 4's
// restart — carried through to both the noteUnconverged report and (when
// N8's recovery does not apply or does not resolve it) restoreDropInSnapshot.
type settleFailure struct {
	unit               string
	aerr               error
	result, condResult string
}

// unitRunsOnce decides whether unit is systemd-oneshot-shaped — settled
// differently than a persistent unit, see unitSettled — by priority:
//
//  1. systemd's own LIVE Type= property (`systemctl show -p Type`). This is
//     authoritative for what actually loaded: real modules (claude-tmux,
//     grok-cli, dev-cell's credential/provision units) declare a hand-tuned
//     unit_body (option A2, lifecycle.renderUnitBodyMode passes it through
//     VERBATIM), and NONE of them declare the structured restart_policy
//     field at all — for a unit_body service that field is INERT (never
//     even read by rendering), so it can never be trusted as this signal's
//     sole source. P1 (review round 13): treating restart_policy:"never" as
//     the ONLY signal, as O5 originally did, misjudged every real
//     unit_body oneshot as PERSISTENT — claude-tmux's credential unit
//     (Type=oneshot, no RemainAfterExit) legitimately exits Result=success
//     on every module reconcile, got refused as a "crash" every time, and
//     the resulting retry force-restarted every active unit of the module
//     (including the live tmux session) roughly every 5 minutes, fleet-wide.
//  2. A static parse of svc.UnitBody for a literal "Type=oneshot" line — a
//     fallback for when the live query itself fails (e.g. the unit was
//     never successfully loaded at all, so systemctl show has nothing
//     authoritative to report).
//  3. svc.RestartPolicy == "never" — kept as an ADDITIONAL signal for a
//     structured (non unit_body) service that genuinely declares it; never
//     the only one consulted, per (1)'s finding.
func unitRunsOnce(ctx context.Context, runner mount.Runner, unit string, svc manifest.Service) bool {
	if t, err := systemd.ShowProperty(ctx, runner, unit, "Type"); err == nil && strings.EqualFold(strings.TrimSpace(t), "oneshot") {
		return true
	}
	if unitBodyDeclaresOneshot(svc.UnitBody) {
		return true
	}
	return strings.EqualFold(strings.TrimSpace(svc.RestartPolicy), "never")
}

// unitBodyDeclaresOneshot scans a verbatim unit_body (option A2) for a
// literal "Type=oneshot" directive line, tolerant of surrounding
// whitespace and case — the same shape systemd itself accepts.
func unitBodyDeclaresOneshot(body string) bool {
	for _, line := range strings.Split(body, "\n") {
		if strings.EqualFold(strings.TrimSpace(line), "Type=oneshot") {
			return true
		}
	}
	return false
}

// unitSettled is the shared "is this unit settled" predicate (O5, review
// round 12, correcting round 11's own N1 predicate in BOTH directions it
// had wrong; P1, review round 13, correcting O5's own run-once SOURCE —
// see unitRunsOnce):
//
//   - PERSISTENT units (unitRunsOnce == false): settled iff ACTIVE, or
//     ConditionResult=="no" (a start genuinely skipped by an unmet
//     Condition*=). Result=="success" is NOT accepted here — a
//     Restart=always unit that exits 0 and immediately relaunches (a crash
//     loop with a clean exit code each time) reports Result=success while
//     genuinely down; round 11's predicate wrongly read that as settled.
//   - RUN-ONCE (oneshot-shaped) units: settled iff ACTIVE, or
//     ConditionResult=="no", or Result=="success" (it ran its course and
//     exited cleanly, exactly as declared). Round 11's predicate SKIPPED
//     these entirely — a genuinely crashed credential/provisioning unit
//     (Result=="exit-code" or similar) never blocked the commit at all.
//
// Shared by upgradeModule's own settle-check loop and
// recoverFromDepartingUnitConflict's post-recovery check (O1), so the two
// call sites can never silently disagree about what "settled" means.
func unitSettled(ctx context.Context, runner mount.Runner, unit string, svc manifest.Service) (settled bool, aerr error, result, condResult string) {
	active, aerr := systemd.IsActive(ctx, runner, unit)
	if aerr == nil && active {
		return true, aerr, "", ""
	}
	result, _ = systemd.ShowProperty(ctx, runner, unit, "Result")
	condResult, _ = systemd.ShowProperty(ctx, runner, unit, "ConditionResult")
	if condResult == "no" {
		return true, aerr, result, condResult
	}
	if unitRunsOnce(ctx, runner, unit, svc) && result == "success" {
		return true, aerr, result, condResult
	}
	return false, aerr, result, condResult
}

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

	// O6 (review round 12): a departing unit N8's own undo could not
	// restart, even after its own in-attempt retry, is a genuine OUTAGE —
	// try it again BEFORE ANYTHING ELSE this tick, ahead of even the
	// backoff gate below (a down unit is more urgent than the digest retry
	// cadence).
	if len(old.PendingUndoUnits) > 0 {
		r.retryPendingUndoUnits(ctx, current, old.ID, old.PendingUndoUnits)
	}

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
	// N2 (review round 11): bound repeated retries of a crash-looping
	// binary. old.PendingDigest/Attempts/LastAttemptUnix describe attempts
	// already made against THIS SAME target digest before this call — the
	// very first attempt (PendingDigest not yet set) and its first retry
	// (Attempts==1, matching M2's own retry-after-failure test, which
	// expects an immediate next-tick retry with no elapsed time) always
	// proceed; only the SECOND retry onward is subject to backoff. Every
	// skipped attempt is surfaced via noteUnconverged rather than silently
	// dropped — PendingDigest/PendingModuleDigests stay set throughout, so
	// the heartbeat keeps reporting the stuck upgrade the whole time.
	if old.PendingDigest == newMod.Digest {
		if allowed, wait, elapsed := backoffAllows(old.PendingDigestAttempts, old.PendingDigestLastAttemptUnix); !allowed {
			r.noteUnconverged("reconciler:upgrade_backoff", newMod.ID, fmt.Errorf(
				"module %s: retry of pending digest %s backed off after %d attempts (%s since the last, %s remaining before the next) — not abandoned, a later reconcile tick retries",
				newMod.ID, newMod.Digest, old.PendingDigestAttempts, elapsed.Round(time.Second), (wait-elapsed).Round(time.Second)))
			return
		}
	} else {
		if old.PendingDigest != "" {
			// O2 (review round 12): re-targeting to a THIRD digest (was pending
			// old.PendingDigest, this attempt is a DIFFERENT one — a revert to
			// the stable Digest never reaches upgradeModule at all, that is
			// reconcile.go's own toReattach path) abandons whatever the old
			// target's own snapshot captured. Prune it now, before taking a
			// fresh snapshot for the new target below, so an abandoned attempt's
			// file can never be mistaken for anything later.
			pruneDropInSnapshotsForModule(r.cfg.StatePath, newMod.ID, newMod.Digest)
		}
		// O8(d) (review round 12): set PendingDigest the MOMENT a fresh
		// attempt begins — before step 1 even runs — not only once step 4
		// is about to restart a unit (that later point sets
		// PendingDigestUnitsTouched, below). A refusal at step 1 (artifact
		// pull/mount), step 2 (security policy) or step 3 (hot-reconcile
		// materialization) never touches a single running unit, but
		// previously left NOTHING recorded — N4 (the server-side stuck-
		// pending-digest sensor) watches PendingDigest/the heartbeat's
		// PendingModuleDigests, so a node stuck failing to even PULL a new
		// digest's artifact, forever, was entirely invisible to it. Chosen
		// over inventing a second, parallel visibility channel: reusing the
		// field N4 already understands needs no new heartbeat shape and no
		// new server-side consumer. This is safe to do unconditionally here
		// (this branch is "fresh target", whether nothing was pending before
		// or a different digest was) BECAUSE the revert path in
		// reconcile.go no longer treats bare PendingDigest presence as
		// "force-restart me" — it consults PendingDigestUnitsTouched
		// instead. This is also where the attempt counter/conflict-recovery
		// flag reset on a re-target (formerly done at the step-4 point,
		// moved up here since PendingDigest is now already settled by the
		// time step 4 runs) lives — Attempts and the N8-attempted flag ARE
		// per-target questions, reset on every re-target.
		//
		// P2 (review round 13, HIGH): PendingDigestUnitsTouched and
		// PendingIntroducedUnits are DELIBERATELY NOT reset here — see their
		// own doc on mount.Module. A re-target does not undo whatever the
		// ABANDONED target's own step 4 already did; resetting either field
		// here lost that fact the moment a THIRD digest was attempted,
		// which is exactly the shape (d2 touched -> d3 refused -> revert)
		// review found: the revert read "nothing touched" and skipped the
		// forced restart d2's own partial restart needed, while d2's
		// own introduced units (e.g. a renamed service's new-only unit)
		// were never cleaned up because nothing remembered d2 introduced
		// them once the episode moved on to d3.
		for i, m := range current.AttachedModules {
			if m.ID == newMod.ID {
				current.AttachedModules[i].PendingDigest = newMod.Digest
				current.AttachedModules[i].PendingDigestAttempts = 0
				current.AttachedModules[i].PendingConflictRecoveryAttempted = false
				// Q3 (review round 14): a fresh target's own steps 1-3 have
				// not run yet — any refusal recorded belonged to whatever
				// was PREVIOUSLY pending, not this one.
				current.AttachedModules[i].PendingDigestActuallyRefused = false
				// Q5 (review round 14): a fresh upgrade episode's own
				// attempts have not been reset-for-revert yet either — see
				// PendingRevertAttemptsReset's own doc.
				current.AttachedModules[i].PendingRevertAttemptsReset = false
				break
			}
		}
		if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
			r.cfg.OnError("reconciler:upgrade_pending_save", fmt.Errorf("module %s: could not persist the pending digest %s before attempting it: %w", newMod.ID, newMod.Digest, err))
		}
	}

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
		r.recordPendingDigestAttempt(current, newMod.ID) // P7: count against backoff
		return                                           // nothing written yet — old fully untouched.
	}

	// R3b (review round 9): snapshot the ACTUAL on-disk bytes of every
	// drop-in file this attempt could touch — old's own units union the new
	// manifest's units (a renamed service's new-only unit correctly has no
	// snapshot entry with existed=true: it never existed before this
	// attempt, so "restoring" it means removing it).
	//
	// N7 (review round 11): taken fresh EVERY attempt, as R3b originally
	// specified, is itself a bug across attempts of the SAME (ID, new
	// digest) target — if attempt 1 wrote step 2's new content and then
	// never reached its own restore (the only realistic way: the agent
	// process itself dying between step 2 and whichever failure branch
	// would have called restoreDropInSnapshot — every REACHABLE Go-level
	// failure branch already restores before returning), attempt 2's "fresh"
	// snapshot would capture attempt 1's own already-new, never-reverted
	// content and mislabel it as the pre-attempt baseline — permanently
	// losing the TRUE old content for anything not protected by N6's
	// alreadyRestarted skip. Fixed by persisting the snapshot to disk once,
	// the FIRST time this (ID, new digest) pair is ever attempted, and
	// reusing the persisted copy on every later attempt at the SAME target
	// — surviving exactly the process-restart case a fresh in-memory-only
	// snapshot cannot. Cleared once the target digest changes (a revert or a
	// re-bump) or the upgrade commits, via clearDropInSnapshotStore.
	dropInSnap, err := loadOrTakeDropInSnapshot(r.cfg.StatePath, newMod.ID, newMod.Digest, old.Digest, current.LastAttachedManifestHashes[old.ID], unionStrings(oldUnits, newMf.UnitNames()))
	if err != nil {
		r.cfg.OnError("reconciler:upgrade_snapshot_persist", fmt.Errorf("module %s digest %s: %w (falling back to an in-memory-only snapshot for this attempt)", newMod.ID, newMod.Digest, err))
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
		//
		// R6 (review round 14): record it too — same gap as attachModule's
		// own K5a branch (reconcile.go). This target's own new-digest units
		// never ran, so nothing here is actually unconfined — but the
		// refusal itself is exactly the kind of event SecurityFailClosedUnits
		// exists to report, and before this it silently never did for this
		// class.
		r.recordSecurityFailClosed(newMf.UnitNames())
		r.recordPendingDigestAttempt(current, newMod.ID) // P7: count against backoff
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
		r.recordPendingDigestAttempt(current, newMod.ID) // P7: count against backoff
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
		r.recordPendingDigestAttempt(current, newMod.ID) // P7: count against backoff
		return
	}

	// M9 (review round 9, HIGH) / O8(d) (review round 12): PendingDigest
	// itself is already set (moved to the top of this function, above — see
	// that block's own doc). What happens HERE, immediately before step 4
	// issues a single restart, is marking PendingDigestUnitsTouched true:
	// the fact reconcile.go's revert path actually needs to decide whether
	// a forced restart is warranted. A module can own several units, and
	// AttachServicesModeOpts keeps attempting the REST of them even after
	// one fails (its own "soft failure" continuation — see that function's
	// doc) — so a partial multi-unit restart is a real, reachable outcome:
	// one unit already running the NEW binary while a later one in the
	// SAME module fails. Cleared at step 7 on commit (newMod, replacing
	// this entry, carries no PendingDigest fields of its own) or on revert.
	//
	// P2 (review round 13): ALSO union THIS target's own introduced units
	// (named by newMf but not by the stable digest's oldUnits) into
	// PendingIntroducedUnits — accumulated across every touched target this
	// episode, not overwritten per-target, so a LATER re-target or revert
	// still knows about a unit an EARLIER, now-abandoned target introduced.
	oldUnitSetForIntroduced := make(map[string]bool, len(oldUnits))
	for _, u := range oldUnits {
		oldUnitSetForIntroduced[u] = true
	}
	var newlyIntroduced []string
	for _, u := range newMf.UnitNames() {
		if !oldUnitSetForIntroduced[u] {
			newlyIntroduced = append(newlyIntroduced, u)
		}
	}
	for i, m := range current.AttachedModules {
		if m.ID == newMod.ID {
			current.AttachedModules[i].PendingDigestUnitsTouched = true
			current.AttachedModules[i].PendingDigestAttempts++
			current.AttachedModules[i].PendingDigestLastAttemptUnix = nowForUpgradeBackoff().Unix()
			// Q3 (review round 14): this target just reached step 4 — it is
			// touched now, not merely "refused"; PendingTouchedDigests/
			// PendingIntroducedUnits take over the render from here.
			current.AttachedModules[i].PendingDigestActuallyRefused = false
			current.AttachedModules[i].PendingIntroducedUnits = unionStrings(current.AttachedModules[i].PendingIntroducedUnits, newlyIntroduced)
			// Q1 (review round 14, MEDIUM): accumulate THIS target's own
			// digest into PendingTouchedDigests — see that field's own doc.
			current.AttachedModules[i].PendingTouchedDigests = unionStrings(current.AttachedModules[i].PendingTouchedDigests, []string{newMod.Digest})
			break
		}
	}
	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		r.cfg.OnError("reconciler:upgrade_pending_save", fmt.Errorf("module %s: could not persist the pending digest %s before restarting: %w", newMod.ID, newMod.Digest, err))
	}
	// O4 (review round 12): save the PENDING digest's own manifest snapshot
	// NOW, not only at step 7's commit. P2 (review round 13) NOTE: the
	// revert path no longer needs THIS specific snapshot to find what units
	// to clean up — PendingIntroducedUnits (above) now answers that
	// directly, and unlike a single-digest snapshot lookup it stays correct
	// across a re-target (see that field's own doc for why a snapshot keyed
	// to only the LATEST pending digest was the bug). Kept anyway: other
	// consumers still want "what did THIS specific digest's manifest say" —
	// the identity/sudoers/egress union (reconcile.go) and a LATER,
	// completely separate upgrade of this same module ID both resolve an
	// old side from the N3 store, independent of this revert-cleanup
	// concern. Step 7 re-saves the same content at commit time (idempotent,
	// harmless).
	if err := manifest.SaveAttachedSnapshot(r.cfg.ManifestRoot, newMod.ID, newMod.Digest, newMf); err != nil {
		r.cfg.OnError("reconciler:attached_snapshot_save", fmt.Errorf("module %s digest %s: %w", newMod.ID, newMod.Digest, err))
	}

	// P1 (review round 13, CORRECTED — this comment previously claimed
	// restart_policy:"never" is "the manifest's existing, authoritative way"
	// to declare a run-once unit; that was false for exactly the units named
	// as examples). Index each NEW-manifest unit's manifest.Service by unit
	// name — NOT a precomputed run-once bool — because run-once-ness is not
	// reliably knowable from the structured restart_policy field alone:
	// claude-tmux's credential unit, grok-cli, and dev-cell's own
	// credential/provision units all declare a hand-tuned unit_body (option
	// A2) with Type=oneshot, and lifecycle.renderUnitBodyMode passes that
	// body through VERBATIM — restart_policy is never even read for a
	// unit_body service. unitSettled (via unitRunsOnce) queries the unit's
	// LIVE systemd Type= property instead, falling back to parsing
	// unit_body and finally to restart_policy:"never" only as a last
	// resort. The settle check below skips a genuine run-once unit's own
	// post-settle inactivity entirely; every persistent unit is
	// settle-checked regardless of whether it happened to be active before
	// this call, since a BRAND-NEW persistent unit this very upgrade
	// introduces was NEVER active before by definition and still needs its
	// first start verified (N8's own departing-unit-conflict recovery below
	// depends on this: a brand-new unit that fails to bind a port must be
	// DETECTED as a failure, not silently skipped as if it were a
	// legitimate run-once exit).
	svcByUnit := make(map[string]manifest.Service, len(newMf.Services))
	for _, svc := range newMf.Services {
		svcByUnit[lifecycle.UnitName(newMod.ID, svc.Name)] = svc
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
	// then confirm every PERSISTENT unit (unitRunsOnce == false) is STILL
	// active before anything irreversible runs.
	//
	// A genuine run-once unit (unitRunsOnce) is skipped entirely — its
	// own inactivity after settling is not new information (N1). For any
	// OTHER unit that reads inactive after settling, a clean, expected
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
	var failures []settleFailure
	for _, unit := range newMf.UnitNames() {
		if settled, aerr, result, condResult := unitSettled(ctx, r.cfg.MountRunner, unit, svcByUnit[unit]); !settled {
			failures = append(failures, settleFailure{unit: unit, aerr: aerr, result: result, condResult: condResult})
		}
	}

	failedUnitNames := make([]string, len(failures))
	for i, f := range failures {
		failedUnitNames[i] = f.unit
	}
	if len(failures) > 0 {
		if old.PendingConflictRecoveryAttempted {
			// O6 (review round 12): fire N8 at most ONCE per (ID, digest) —
			// a retry that keeps hitting the same settle failure must not
			// re-run the stop/start dance against the same departing unit
			// on every backoff cycle, including one the undo step already
			// restored. Decline silently into the ordinary refusal path.
			r.noteUnconverged("reconciler:upgrade_port_conflict_skipped", newMod.ID, fmt.Errorf(
				"module %s: N8 conflict recovery already attempted once for digest %s on an earlier tick — declining to repeat it so a departing unit already restored is not churned again",
				newMod.ID, newMod.Digest))
		} else {
			for i, m := range current.AttachedModules {
				if m.ID == newMod.ID {
					current.AttachedModules[i].PendingConflictRecoveryAttempted = true
					break
				}
			}
			if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
				r.cfg.OnError("reconciler:upgrade_port_conflict_flag_save", fmt.Errorf("module %s: could not persist the N8-attempted flag: %w", newMod.ID, err))
			}
			if r.recoverFromDepartingUnitConflict(ctx, current, old, oldUnits, newMf, failedUnitNames, svcByUnit) {
				// N8 (review round 11, MEDIUM): every failing unit was NEW-THIS-
				// UPGRADE (never existed under the old digest) and a departing
				// unit was still active — stopping it freed whatever it held
				// (most plausibly a port) and the new unit(s) came up once
				// retried. This IS a version-upgrade restart (rule 2), not a
				// refusal side effect — see recoverFromDepartingUnitConflict's
				// own doc. Fall through to the commit exactly as if the settle
				// check had passed outright.
				failures = nil
			}
		}
	}

	for _, f := range failures {
		r.noteUnconverged("reconciler:upgrade_settle_check", newMod.ID, fmt.Errorf(
			"module %s: unit %s did not stay active through the %s settle window after restart (is-active err=%v, Result=%q, ConditionResult=%q) — refusing to delta-stop, unmount, or commit; a dependent unit may already have stopped as a propagation of this failure (documented A3 residual)",
			newMod.ID, f.unit, r.cfg.UpgradeSettleWindow, f.aerr, f.result, f.condResult))
	}
	if len(failures) > 0 {
		restoreDropInSnapshot(dropInSnap, restartedUnits, r.cfg.OnError)
		return
	}

	// Every step through the new digest's own attach has now succeeded and
	// settled — proceed to the IRREVERSIBLE cutover.

	// Step 5: delta-stop units the old digest owned that the new manifest
	// no longer names (a renamed or removed service). P2 (review round 13):
	// unioned with old.PendingIntroducedUnits — a unit an EARLIER, now-
	// abandoned target introduced (e.g. d2's own new-only unit, if THIS
	// commit is actually d3) is owned by neither oldUnits (the stable
	// digest never named it) nor newMf (the committing target may not name
	// it either) and would otherwise never be stopped at all.
	r.stopDepartingUnits(ctx, old.ID, unionStrings(oldUnits, old.PendingIntroducedUnits), newMf.UnitNames())

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
	// N3 (review round 11): persist the NEW digest's own snapshot at the
	// moment it becomes the attached, running content — a LATER bump of
	// this same module ID reads it as ITS old side, independent of
	// whatever a still-later tick's own fetch attempt overwrites the
	// ID-keyed "latest fetch" cache with.
	if err := manifest.SaveAttachedSnapshot(r.cfg.ManifestRoot, newMod.ID, newMod.Digest, newMf); err != nil {
		r.cfg.OnError("reconciler:attached_snapshot_save", fmt.Errorf("module %s digest %s: %w", newMod.ID, newMod.Digest, err))
	}
	// N7 (review round 11): the drop-in snapshot's job ends at commit —
	// clear it so a FUTURE upgrade attempt of this same module ID never
	// mistakes a stale persisted file for its own fresh baseline. O2
	// (review round 12): prune EVERY leftover snapshot file for this module
	// ID, not just the one just committed — nothing should still be
	// pending, so nothing should be kept.
	pruneDropInSnapshotsForModule(r.cfg.StatePath, newMod.ID, "")
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

// recoverFromDepartingUnitConflict is N8's minimal fix (review round 11,
// MEDIUM): a renamed service sharing a port (or any other exclusive
// resource) with the unit it replaces deadlocks under the round-9 in-place
// design, because a departing unit is never stopped (step 5) until the new
// unit is already confirmed settled (step 4's own settle check) — but the
// new unit can never bind the resource while the old one still holds it.
// Detected narrowly, not generally: EVERY failing unit must be NEW-THIS-
// UPGRADE (absent from oldUnits — a unit the old digest never owned at all
// cannot be "the same process, just crashed", so its failure is never a
// genuine settle-check crash, only ever a bind conflict or a bad config),
// AND at least one departing unit (one oldUnits names that newMf no longer
// does) must still be ACTIVE. Any other shape — a SHARED unit failing, or
// no departing unit actually holding anything — is a real crash and this
// declines to act at all, leaving the ordinary refusal path in charge.
//
// Recovery itself is a single, non-looping attempt, kept deliberately
// small per the review's own instruction: stop the departing unit(s) (a
// rule-(2) restart — the invariant's own carve-out for a genuine version
// upgrade, not a refusal side effect), retry `start` on the failed new
// unit(s) once, settle, and re-check with the SAME settled predicate the
// main check uses (O1, review round 12 — an immediate is-active read is
// worthless for a Type=simple unit that crashes inside the settle window,
// exactly the bug this recovery exists to avoid committing on top of).
// Recovered: the caller treats the settle check as having passed. Not
// recovered: the departing unit is started again — retried once if the
// first restart fails (O6) — and the ordinary refusal path still fires. A
// departing unit the retried undo STILL cannot restart is persisted onto
// PendingUndoUnits so a LATER tick tries it again before anything else
// (retryPendingUndoUnits), since a stopped-and-not-restored departing unit
// is a genuine outage, not merely a stuck upgrade.
func (r *Reconciler) recoverFromDepartingUnitConflict(ctx context.Context, current *mount.State, old mount.Module, oldUnits []string, newMf *manifest.Manifest, failedUnits []string, svcByUnit map[string]manifest.Service) bool {
	oldUnitSet := make(map[string]bool, len(oldUnits))
	for _, u := range oldUnits {
		oldUnitSet[u] = true
	}
	for _, u := range failedUnits {
		if oldUnitSet[u] {
			return false // a SHARED unit failed — a real crash, not this class.
		}
	}

	newUnitSet := make(map[string]bool, len(newMf.UnitNames()))
	for _, u := range newMf.UnitNames() {
		newUnitSet[u] = true
	}
	var departing []string
	for _, u := range oldUnits {
		if newUnitSet[u] {
			continue
		}
		if active, err := systemd.IsActive(ctx, r.cfg.MountRunner, u); err == nil && active {
			departing = append(departing, u)
		}
	}
	if len(departing) == 0 {
		return false // nothing departing is even holding anything.
	}

	// P8 (review round 13, MEDIUM): persist PendingUndoUnits = departing
	// BEFORE stopping a single one of them. Before this fix,
	// PendingConflictRecoveryAttempted=true was persisted by the CALLER,
	// well before departing was even known, and the stillDown/
	// PendingUndoUnits save only ever happened AFTER the stop-then-start-
	// then-settle sequence below. A crash anywhere in that window (after
	// stopping a departing unit, before this function returns) left
	// PendingConflictRecoveryAttempted=true on disk with no record of
	// which unit this attempt had just stopped — the caller's own O6
	// dedupe declines to retry a (ID, digest) it believes already ran
	// once, so the stopped unit was never retried by anything. Recording
	// the full candidate list up front means a crash at ANY point below
	// leaves retryPendingUndoUnits (O6/P4) something concrete to act on
	// next tick, regardless of how far this attempt got.
	if current != nil {
		for i, m := range current.AttachedModules {
			if m.ID == old.ID {
				current.AttachedModules[i].PendingUndoUnits = unionStrings(current.AttachedModules[i].PendingUndoUnits, departing)
				break
			}
		}
		if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
			r.cfg.OnError("reconciler:upgrade_port_conflict_undo_save", fmt.Errorf("module %s: could not persist departing unit(s) %v before stopping them: %w", old.ID, departing, err))
		}
	}

	for _, d := range departing {
		if err := systemd.Action(ctx, r.cfg.MountRunner, d, systemd.Stop); err != nil {
			r.cfg.OnError("reconciler:upgrade_port_conflict_stop", fmt.Errorf("module %s unit %s: %w", old.ID, d, err))
		}
	}

	for _, unit := range failedUnits {
		if err := systemd.Action(ctx, r.cfg.MountRunner, unit, systemd.Start); err != nil {
			r.cfg.OnError("reconciler:upgrade_port_conflict_start", fmt.Errorf("module %s unit %s: %w", old.ID, unit, err))
		}
	}

	// O1 (review round 12): settle exactly like the main check does — an
	// immediate is-active read after `start` proves only that ExecStart was
	// launched, not that the new unit stayed up past whatever the departing
	// unit's own release of the resource exposed (a crash-on-bind, a
	// migration that only now runs against a real port). Uses the SAME
	// predicate (unitSettled) so the two call sites can never silently
	// disagree about "settled".
	sleepForUpgradeSettle(r.cfg.UpgradeSettleWindow)
	recovered := true
	for _, unit := range failedUnits {
		if settled, _, _, _ := unitSettled(ctx, r.cfg.MountRunner, unit, svcByUnit[unit]); !settled {
			recovered = false
		}
	}

	if recovered {
		r.cfg.OnError("reconciler:upgrade_port_conflict_recovered", fmt.Errorf(
			"module %s: stopped departing unit(s) %v to let new unit(s) %v bind — this is a version-upgrade restart, not a refusal", old.ID, departing, failedUnits))
		// P8: every departing unit is DELIBERATELY down (replaced by the new
		// unit it was blocking), not stuck — retract the pre-stop candidate
		// list above so nothing later retries "restarting" it.
		if current != nil {
			removeFromPendingUndoUnits(current, old.ID, departing)
			if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
				r.cfg.OnError("reconciler:upgrade_port_conflict_undo_save", fmt.Errorf("module %s: could not clear the recovered departing unit(s) %v: %w", old.ID, departing, err))
			}
		}
		return true
	}

	// Undo: bring the departing unit back rather than leave the module with
	// neither side running. O6 (review round 12): retry ONCE within this
	// same attempt before giving up — a transient failure (the same class
	// step 4's own restart can hit) must not be treated as permanent on the
	// first try.
	var stillDown []string
	for _, d := range departing {
		if err := systemd.Action(ctx, r.cfg.MountRunner, d, systemd.Start); err != nil {
			if err2 := systemd.Action(ctx, r.cfg.MountRunner, d, systemd.Start); err2 != nil {
				stillDown = append(stillDown, d)
				r.cfg.OnError("reconciler:upgrade_port_conflict_undo_failed", fmt.Errorf(
					"module %s: restarting departing unit %s after a failed conflict-recovery attempt also failed TWICE — module may now be fully down; a later tick keeps retrying this unit before anything else: %w",
					old.ID, d, err2))
			}
		}
	}
	// P8: replace the pre-stop candidate list with exactly what remains
	// down — a unit the undo successfully restarted must not linger in
	// PendingUndoUnits forever just because it was in the original,
	// pre-stop candidate list persisted above.
	if current != nil {
		removeFromPendingUndoUnits(current, old.ID, departing)
		if len(stillDown) > 0 {
			for i, m := range current.AttachedModules {
				if m.ID == old.ID {
					current.AttachedModules[i].PendingUndoUnits = unionStrings(current.AttachedModules[i].PendingUndoUnits, stillDown)
					break
				}
			}
		}
		if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
			r.cfg.OnError("reconciler:upgrade_port_conflict_undo_save", fmt.Errorf("module %s: could not persist the stuck departing unit(s) %v: %w", old.ID, stillDown, err))
		}
	}
	return false
}

// removeFromPendingUndoUnits removes each of removed from moduleID's
// PendingUndoUnits in current (in place, not yet persisted — callers save
// afterward, typically alongside another field they are updating in the
// same transaction). Used by recoverFromDepartingUnitConflict (P8, review
// round 13) to retract its own pre-stop candidate list once each unit's
// fate is known (recovered, or replaced by the post-undo stillDown set),
// without disturbing an unrelated, still-pending entry for the same module
// left by some OTHER attempt.
func removeFromPendingUndoUnits(current *mount.State, moduleID string, removed []string) {
	removeSet := make(map[string]bool, len(removed))
	for _, u := range removed {
		removeSet[u] = true
	}
	for i, m := range current.AttachedModules {
		if m.ID != moduleID {
			continue
		}
		kept := make([]string, 0, len(m.PendingUndoUnits))
		for _, u := range m.PendingUndoUnits {
			if !removeSet[u] {
				kept = append(kept, u)
			}
		}
		current.AttachedModules[i].PendingUndoUnits = kept
		break
	}
}

// retryPendingUndoUnits is O6's own priority recovery (review round 12): a
// departing unit N8's undo could not restart even after its own in-attempt
// retry is a genuine OUTAGE, not merely a stuck upgrade — this runs before
// anything else in upgradeModule (even before the backoff gate, since a
// down unit is more urgent than the digest retry cadence) and tries once
// more, every tick, until it is confirmed active again. Cleared as soon as
// a unit is confirmed up; a unit that is still down stays on the list for
// the NEXT tick to try again.
func (r *Reconciler) retryPendingUndoUnits(ctx context.Context, current *mount.State, moduleID string, units []string) {
	if len(units) == 0 {
		return
	}
	stillDown := make([]string, 0, len(units))
	for _, unit := range units {
		if err := systemd.Action(ctx, r.cfg.MountRunner, unit, systemd.Start); err != nil {
			r.cfg.OnError("reconciler:upgrade_port_conflict_undo_retry", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
		}
		if active, err := systemd.IsActive(ctx, r.cfg.MountRunner, unit); err != nil || !active {
			stillDown = append(stillDown, unit)
		}
	}
	// Q7 (review round 14, LOW, rule-1 edge): write to EVERY matching row
	// for this ID, not just the first — the M4 duplicate-state-entry case
	// (see O8(a)'s own doc, reconcile.go) means a second row could
	// independently carry its own view of PendingUndoUnits; leaving it
	// unwritten would strand a unit's retry result on a row nothing else
	// reads while the visible (first) row silently disagrees.
	for i, m := range current.AttachedModules {
		if m.ID == moduleID {
			current.AttachedModules[i].PendingUndoUnits = stillDown
		}
	}
	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		r.cfg.OnError("reconciler:upgrade_port_conflict_undo_retry_save", fmt.Errorf("module %s: could not persist the retried departing unit(s) state: %w", moduleID, err))
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
// old policy" silently re-wrote the already-wrong new one instead.
//
// N7 (review round 11) CORRECTION to this doc's original claim: a snapshot
// taken fresh on EVERY attempt is NOT independent of what an earlier
// attempt wrote after all — see loadOrTakeDropInSnapshot, which now takes
// this exactly ONCE per (ID, new digest) and persists it, for the reason
// explained there. This function itself is unchanged; it is simply no
// longer called on every attempt.
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

// persistedDropInSnapshot mirrors dropInSnapshot for JSON persistence (N7,
// review round 11). dropInSnapshot's own fields are deliberately unexported
// (nothing outside upgrade.go constructs one) — this is a separate,
// exported-field DTO used only for the on-disk round-trip; `dir` is not
// persisted since it is always re-derivable from `unit` alone via
// security.SystemdDropInRoot(), and a persisted root recorded at save time
// would go stale if that root is ever reconfigured before the matching load.
type persistedDropInSnapshot struct {
	Unit       string
	Filename   string
	Existed    bool
	Body       string
	Unreadable bool
}

// persistedDropInSnapshotFile is the on-disk envelope (O2, review round 12):
// wraps the snapshot entries with the identity of the STATE they were taken
// against — the old digest's own Digest and its attach-stamp
// (LastAttachedManifestHashes[old.ID]) at the moment this snapshot was
// captured. loadOrTakeDropInSnapshot refuses to reuse a persisted file
// whose recorded identity no longer matches the CURRENT entry: if either
// changed since the snapshot was taken, whatever it captured is no longer
// "the true old policy" and reusing it would restore a STALE, possibly
// LOOSER policy over a manifest edit that tightened it in between (O2's own
// finding — see loadOrTakeDropInSnapshot's doc for the exact sequence).
type persistedDropInSnapshotFile struct {
	OldDigest      string
	OldAttachStamp string
	Snapshots      []persistedDropInSnapshot
}

// dropInSnapshotStorePath returns stateDir/upgrade-snapshots/<moduleID>_
// <digest>.json — one file per (moduleID, digest) pair, sanitized the same
// way mount.Layout sanitizes a digest for a path component (':' is not a
// safe filename character on every filesystem this agent targets).
func dropInSnapshotStorePath(stateDir, moduleID, digest string) string {
	return filepath.Join(stateDir, "upgrade-snapshots", moduleID+"_"+sanitizeForFilename(digest)+".json")
}

func sanitizeForFilename(s string) string {
	san := make([]byte, 0, len(s))
	for _, c := range []byte(s) {
		switch {
		case c == ':' || c == '/' || c == ' ':
			san = append(san, '_')
		default:
			san = append(san, c)
		}
	}
	return string(san)
}

// loadOrTakeDropInSnapshot is N7's own fix (review round 11), corrected by
// O2 (review round 12, SECURITY): the FIRST time (moduleID, digest) is
// attempted, it takes a fresh snapshot and persists it — alongside
// oldDigest and oldAttachStamp, the identity of the state it was taken
// against — to statePath's directory (the same durable, survives-a-reboot
// location state.json itself lives in). Every LATER attempt at the SAME
// target reads the persisted copy back ONLY IF oldDigest/oldAttachStamp
// still match the CURRENT call's own values; a mismatch means something
// changed the old digest's actual content since the snapshot was taken
// (the exact O2 sequence: d2 refused — snapshot captures d1's ORIGINAL
// policy; revert to d1 with d1's manifest EDITED to tighten a policy field
// — the ordinary reattach path correctly writes the tightened content and
// bumps d1's attach-stamp; d2 refused AGAIN — the STALE persisted snapshot,
// keyed only by digest, would restore the ORIGINAL, untightened content
// over the currently-correct tightened one) — discarded, and a fresh
// snapshot is taken and persisted with the CURRENT identity instead. A
// read/decode/write error also degrades to an in-memory-only fresh
// snapshot (the caller surfaces it via OnError) rather than aborting the
// upgrade attempt entirely — persistence is a durability improvement, not
// a hard prerequisite for a single attempt to proceed.
func loadOrTakeDropInSnapshot(statePath, moduleID, digest, oldDigest, oldAttachStamp string, units []string) ([]dropInSnapshot, error) {
	path := dropInSnapshotStorePath(filepath.Dir(statePath), moduleID, digest)
	if body, err := os.ReadFile(path); err == nil {
		var file persistedDropInSnapshotFile
		if err := json.Unmarshal(body, &file); err != nil {
			return snapshotUnitDropIns(units), fmt.Errorf("decode persisted drop-in snapshot %s: %w", path, err)
		}
		if file.OldDigest == oldDigest && file.OldAttachStamp == oldAttachStamp {
			root := security.SystemdDropInRoot()
			snaps := make([]dropInSnapshot, 0, len(file.Snapshots))
			for _, p := range file.Snapshots {
				snaps = append(snaps, dropInSnapshot{
					unit: p.Unit, dir: filepath.Join(root, p.Unit+".d"), filename: p.Filename,
					existed: p.Existed, body: p.Body, unreadable: p.Unreadable,
				})
			}
			return snaps, nil
		}
		// O2: STALE — the old digest's identity moved since this file was
		// written. Fall through to take (and persist) a fresh one below,
		// exactly as if no file existed at all.
	}
	fresh := snapshotUnitDropIns(units)
	persisted := make([]persistedDropInSnapshot, 0, len(fresh))
	for _, s := range fresh {
		persisted = append(persisted, persistedDropInSnapshot{
			Unit: s.unit, Filename: s.filename, Existed: s.existed, Body: s.body, Unreadable: s.unreadable,
		})
	}
	file := persistedDropInSnapshotFile{OldDigest: oldDigest, OldAttachStamp: oldAttachStamp, Snapshots: persisted}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fresh, fmt.Errorf("mkdir %s: %w", filepath.Dir(path), err)
	}
	if err := fsutil.AtomicWriteJSON(path, file, 0o644); err != nil {
		return fresh, fmt.Errorf("persist drop-in snapshot %s: %w", path, err)
	}
	return fresh, nil
}

// clearDropInSnapshotStore removes the persisted snapshot for (moduleID,
// digest), once it is no longer needed: the upgrade committed (step 7), the
// entry reverted (N2's revert path clears PendingDigest the same tick), or
// a later tick re-targets a DIFFERENT digest entirely (the M9/N2 PendingDigest
// bookkeeping already treats that as a fresh attempt with its own counter —
// this store must not let a stale snapshot from an abandoned target leak
// into an unrelated later one). Best-effort: a leftover file wastes a
// little disk and nothing more — the (moduleID, digest) filename can never
// collide with a DIFFERENT still-in-flight attempt's own file.
func clearDropInSnapshotStore(statePath, moduleID, digest string) {
	if digest == "" {
		return
	}
	_ = os.Remove(dropInSnapshotStorePath(filepath.Dir(statePath), moduleID, digest))
}

// pruneDropInSnapshotsForModule is O2's own GC half (review round 12): on
// commit, on a revert, or when re-targeting to a THIRD digest, remove EVERY
// <moduleID>_*.json snapshot file for this module except (optionally)
// keepDigest's own — a defense-in-depth companion to the identity check
// above, not a substitute for it: this bounds how many abandoned attempts'
// files can accumulate per module, independent of whether any one of them
// would have been judged stale on its own. Best-effort; a leftover file
// wastes disk, nothing more (a LATER load still validates identity before
// ever trusting one).
func pruneDropInSnapshotsForModule(statePath, moduleID, keepDigest string) {
	dir := filepath.Join(filepath.Dir(statePath), "upgrade-snapshots")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return // nothing to prune, or the dir doesn't exist yet — both fine.
	}
	prefix := moduleID + "_"
	var keepName string
	if keepDigest != "" {
		keepName = moduleID + "_" + sanitizeForFilename(keepDigest) + ".json"
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasPrefix(name, prefix) {
			continue
		}
		if keepName != "" && name == keepName {
			continue
		}
		_ = os.Remove(filepath.Join(dir, name))
	}
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
