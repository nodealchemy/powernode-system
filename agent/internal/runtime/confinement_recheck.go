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
// path's first reconcile tick forces EVERY currently-attached,
// manifest-resolved module through the ordinary reattach path regardless of
// whether its stamp matches — attachModule's own applyModuleSecurityPolicy
// call re-renders and re-compares the drop-in bytes against whatever
// compose actually wrote, and W1's own changed-units plumbing reloads/
// restarts a running unit if they diverge.
//
// Deliberately NOT the state-rebase machinery's own report-only/sentinel-
// gated enforcement (state_rebase.go): re-applying a manifest's OWN
// already-approved confinement is not a destructive operation needing a
// per-composition operator approval the way DROPPING a state entry is — it
// is exactly what an ordinary manifest-only reattach already does, just
// triggered by a different signal (a new boot, not a manifest edit).
//
// ALTERNATIVE CONSIDERED: comparing rendered drop-in bytes against on-disk
// bytes directly, as part of the reattach gate itself, instead of a
// once-per-composition force. Rejected: it would need every drop-in's
// rendered content computed for every attached unit on EVERY tick just to
// decide whether to reattach — the exact same rendering work
// applyModuleSecurityPolicy already does INSIDE attachModule, just
// duplicated one layer up purely to answer "should I call attachModule at
// all". The composition-keyed force is cheaper (one boot-breadcrumb read
// per tick, one string compare, and the real re-render happens at most once
// per boot) and mirrors an already-reviewed, already-shipped pattern
// (state_rebase.go) instead of inventing a second one.

import "github.com/nodealchemy/powernode-system/agent/internal/lifecycle"

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
