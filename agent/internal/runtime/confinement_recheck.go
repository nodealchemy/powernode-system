package runtime

// W2 (IMP-caef5c00d63f round W, HIGH): boot-composition-keyed drop-in
// reverification.
//
// The attach stamp (state.json, /persist) survives a reboot; the security
// drop-ins themselves live in the tmpfs upper, rewritten fresh by EVERY
// boot's own compose step — possibly by an OLDER initramfs agent binary
// that renders a different (or no) drop-in for the same manifest content.
// Since the stamp comparison the live reattach loop uses (attachStamp) is
// computed from MANIFEST content, not from what is actually on disk, a boot
// whose compose wrote a stale/absent drop-in for an already-stamped module
// is invisible to it: the stamp still matches, so the module never
// re-enters toReattach, and the drop-in stays wrong until the next manifest
// edit (which may never come).
//
// Fix: once per boot COMPOSITION (keyed the same way the state rebase is,
// stateRebaseKeyOf — boot id + compose time, not the kernel boot id alone,
// since a soft-reboot recomposes under the SAME kernel boot id), the live
// path's first reconcile tick re-applies EVERY currently-attached,
// manifest-resolved module's own security drop-ins regardless of whether
// its stamp matches, via reconfirmConfinementIfNeeded below — and W1/X1's
// own changed-units plumbing reloads/restarts a running unit if they
// diverge.
//
// X4 (IMP-caef5c00d63f round X, MEDIUM — delta on the ORIGINAL W1-round
// design): the original design forced every such module through the FULL
// ordinary reattach path (attachModule: mountModuleArtifact's whole-blob
// Pull/verify/cosign check, policy.Apply's MAC profile reload, then
// hotReconcileIfNeeded's SyncModuleFiles) once per boot, unconditionally —
// none of which has anything to do with what this fix exists to catch. A
// stale on-disk drop-in only needs its OWN drop-in stage re-run:
// decideSecurityPolicyForAttach (pure) + writeSecurityDropIns (the
// writers), via applyModuleSecurityDropInsOnly (reconcile.go). Re-pulling
// the blob and re-verifying cosign on every boot regardless of whether
// anything diverged is real, size-proportional cost for no benefit here;
// re-loading a MAC profile is unrelated to a stale capabilities/seccomp/
// userns drop-in; and SyncModuleFiles can overwrite content a LATER
// runtime write already rewrote (its own doc, hotReconcileIfNeeded).
//
// X3 (IMP-caef5c00d63f round X, MEDIUM): the composition is marked
// reconfirmed (mount.State.ConfinementReconfirmedAgainst) ONLY after every
// module this pass could reach a decision for succeeded — never marked
// before processing. The ORIGINAL design marked it unconditionally before
// the toReattach loop even ran, reasoning (wrongly) that "a module whose
// reattach genuinely fails this tick is not lost: the ordinary stamp-diff
// check re-queues it" — but the module's stamp already MATCHES (that is
// the entire premise this fix exists for), so a stamp-diff re-queue never
// fires for it; marking the key done regardless of outcome silently
// dropped a failed module's own recheck for the rest of the boot. Now: any
// module this pass could not cleanly resolve (a policy-decision error, a
// drop-in write that failed closed, or one still confinement-pending after
// attachModuleServices) leaves the whole composition's key UNSET, so the
// NEXT tick retries EVERY forced module again — cheap and idempotent under
// X4's narrowing, unlike a retry of the original full-attachModule design
// would have been.
//
// Deliberately NOT the state-rebase machinery's own report-only/sentinel-
// gated enforcement (state_rebase.go): re-applying a manifest's OWN
// already-approved confinement is not a destructive operation needing a
// per-composition operator approval the way DROPPING a state entry is — it
// is exactly what an ordinary manifest-only reattach already does, just
// triggered by a different signal (a new boot, not a manifest edit).
//
// ALTERNATIVE CONSIDERED (still applies post-X4): comparing rendered
// drop-in bytes against on-disk bytes directly, as part of the reattach
// gate itself, instead of a once-per-composition force. Rejected: it would
// need every drop-in's rendered content computed for every attached unit
// on EVERY tick just to decide whether anything diverged, duplicating
// decideSecurityPolicyForAttach's own rendering work one layer up purely to
// answer "did anything change". The composition-keyed force is cheaper
// (one boot-breadcrumb read per tick, one string compare, and the real
// re-render happens at most once per boot — now via the narrow drop-in-only
// path X4 introduces, not the full attach) and mirrors an already-reviewed,
// already-shipped pattern (state_rebase.go) instead of inventing a second
// one.

import (
	"context"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// confinementRecheckKey identifies the CURRENT boot composition, or reports
// ok=false when it cannot be determined (a chroot/cloud_init node with no
// boot-fixed root to have drifted, or no usable boot breadcrumb) — the SAME
// three checks rebaseStateAgainstBoot applies before trusting a breadcrumb,
// restated here rather than shared as one function because the two callers
// react to a failed check differently (state rebase reports a skip
// condition through its own eval machinery; this one simply declines to
// force anything this tick, silently, exactly like never having reached the
// tick's own toReattach loop with a divergent stamp would).
func (r *Reconciler) confinementRecheckKey() (key string, ok bool) {
	rootMode, err := pivotAwareRootModeChecked()
	if err != nil || rootMode != lifecycle.RootModeNative {
		return "", false
	}
	hdr, err := loadBreadcrumbHeader(BootBreadcrumbPath)
	if err != nil || hdr.BootID == "" || hdr.Incomplete {
		return "", false
	}
	nowBoot := currentBootID()
	if nowBoot == "" || hdr.BootID != nowBoot {
		return "", false
	}
	return stateRebaseKeyOf(hdr.BootID, hdr.ComposedAt), true
}

// reconfirmConfinementIfNeeded (X3/X4, IMP-caef5c00d63f round X) is W2's own
// once-per-boot-composition drop-in recheck, narrowed to touch only the
// drop-in stage — see this file's own doc for the full reasoning. Runs
// AFTER the ordinary attach/reattach loops and upgrades have settled for
// this tick (RunOnce calls it right before reportKnownDegradedUnits), over
// every module CURRENTLY attached: re-running it against a module this SAME
// tick's own reattach loop already handled is a pure no-op
// (writeDropInFile's own skip-if-identical), not a correctness concern —
// kept simple deliberately rather than tracking "already handled this
// tick" as a second set to reason about.
func (r *Reconciler) reconfirmConfinementIfNeeded(ctx context.Context, current *mount.State, manifests map[string]*manifest.Manifest) {
	key, ok := r.confinementRecheckKey()
	if !ok || current.ConfinementReconfirmedAgainst == key {
		return
	}

	allOK := true
	for _, mod := range current.AttachedModules {
		mf, ok := manifests[mod.ID]
		if !ok {
			// Same fallback as the ordinary reattach gate: nothing fresh to
			// re-check this module against on a tick whose manifest fetch
			// for it failed. Does not block marking the composition
			// reconfirmed — a module this tick genuinely could not reach is
			// no different from one the ordinary path also could not reach.
			continue
		}
		// J3 (review round 5, restated here): a module whose decision this
		// pass WAS reached, even a refusal, is a fresh answer and must
		// replace whatever fail-closed state was published before.
		r.securityPolicyAttemptedUnits = append(r.securityPolicyAttemptedUnits, mf.UnitNames()...)

		changedUnits, failedUnits, err := r.applyModuleSecurityDropInsOnly(mod, mf)
		if err != nil {
			allOK = false
			r.cfg.OnError("reconciler:confinement_recheck_failed", fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		if len(failedUnits) > 0 {
			allOK = false
			r.recordSecurityFailClosed(failedUnits)
			r.cfg.OnError("reconciler:confinement_recheck_dropin_fail_closed",
				fmt.Errorf("module %s: security drop-in re-apply failed for unit(s) %v during the once-per-boot-composition confinement recheck — refusing to consider this composition reconfirmed", mod.ID, failedUnits))
			continue
		}
		r.recordSecurityFailClosedRecovered(mf.UnitNames())
		if pending := r.attachModuleServices(ctx, current, mod, mf, changedUnits); len(pending) > 0 {
			// X1's own pending machinery already reports + persists this;
			// the composition-level key stays withheld below so this
			// module's drop-in stage is re-examined again next tick too —
			// cheap under X4's narrowing, unlike the ORIGINAL full-attach
			// design's equivalent retry would have been.
			allOK = false
		}
	}
	if allOK {
		// X3: marked done for THIS composition only once every module this
		// pass could reach a decision for resolved cleanly — see this
		// file's own doc for why marking it BEFORE processing (the original
		// design) silently dropped a failed module's own recheck.
		current.ConfinementReconfirmedAgainst = key
	}
}
