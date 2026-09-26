package runtime

import (
	"fmt"
	"net"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Guard against a self-hosting node detaching its own control plane.
//
// THE INCIDENT THIS EXISTS FOR (ops-hub, 2026-07-28 23:51 UTC). The hourly
// CVE feed job saturated Postgres — every query 130-240ms across ~8
// concurrent requests. The agent's module fetches began timing out, and on a
// tick in that window the desired set came back without the platform's own
// modules. The reconciler did exactly what it is designed to do and detached
// them: sidekiq, rails, traefik, caddy, redis — in reverse-priority order,
// stopping the services that answer /api/v1/system/node_api/modules.
//
// Because ops-hub hosts the platform it reconciles against, that is
// unrecoverable BY CONSTRUCTION: the list that would say "re-attach these"
// is served by what was just detached. The node sat in a connection-refused
// loop for 51 minutes and only a reboot (recomposing from LKG) brought it
// back.
//
// THE SHAPE OF THE FIX. The tempting framing is "identify the control-plane
// module and protect it", but that attribution is unreliable: traefik owns
// the listening socket while rails sits behind it, and detaching either is
// equally fatal. The invariant that actually holds is broader and simpler —
// on a self-hosted node, do not LIVE-detach a module that runs services.
//
// This costs nothing durable. Removing a module from the composition already
// takes full effect at the next recompose, when the union is rebuilt without
// it; refusing the live detach only defers the removal to that reboot, which
// is the documented behaviour for composition changes anyway. So the guard
// trades an operation with no lasting benefit for the elimination of an
// unrecoverable failure mode.
//
// Deliberately NOT applied to remote-platform nodes: there, an erroneous
// detach is self-correcting, because the platform stays up and the next tick
// re-attaches. The asymmetry is the whole point.

// Seams so the self-host probe is exercisable without real DNS or a real
// interface list.
var (
	lookupHostIPs     = net.LookupHost
	localInterfaceIPs = func() ([]string, error) {
		addrs, err := net.InterfaceAddrs()
		if err != nil {
			return nil, err
		}
		out := make([]string, 0, len(addrs))
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok {
				out = append(out, ipnet.IP.String())
			}
		}
		return out, nil
	}
)

// selfHosted reports whether cfg.PlatformURL points at THIS node.
//
// The result LATCHES once true and is never recomputed. DNS is frequently
// the first casualty of the kind of degradation this guard exists for, and a
// probe that answered "not self-hosted" during a resolver failure would
// disarm the protection at precisely the wrong moment. Latching false-to-true
// only (never true-to-false) means the worst a flaky probe can do is arm the
// guard late, never drop it.
func (r *Reconciler) selfHosted() bool {
	r.selfHostMu.Lock()
	defer r.selfHostMu.Unlock()
	if r.selfHostLatched {
		return true
	}
	if r.cfg.PlatformURL == "" {
		return false
	}

	host := hostFromURL(r.cfg.PlatformURL)
	if host == "" {
		return false
	}
	platformIPs, err := lookupHostIPs(host)
	if err != nil || len(platformIPs) == 0 {
		return false
	}
	locals, err := localInterfaceIPs()
	if err != nil {
		return false
	}
	localSet := make(map[string]bool, len(locals))
	for _, l := range locals {
		localSet[strings.TrimSpace(l)] = true
	}
	for _, p := range platformIPs {
		if localSet[strings.TrimSpace(p)] {
			r.selfHostLatched = true
			return true
		}
	}
	return false
}

// filterUnsafeDetaches drops service-bearing modules from a detach set when
// this node hosts the platform it reconciles against. Returns the stack that
// is safe to detach live.
//
// A module with no manifest is treated as service-bearing: absence of proof
// is not proof of absence, and on a self-hosted node being wrong is
// unrecoverable while being over-cautious costs only a deferred removal.
//
// A VERSION BUMP IS NOT A REMOVAL and, as far as THIS function's own
// concern (an erroneous "removal" reading of a degraded FetchAssignedModules
// response) goes, must pass through untouched. The old digest lands in
// toDetach and the new one in toAttach, so refusing that detach on THAT
// basis would leave both versions attached at once and break upgrades on
// exactly the node that most needs to receive them. An upgrade is also
// self-correcting in a way a removal is not: the replacement immediately
// re-provides the same services. Only a module with no same-ID successor is
// genuinely leaving, and only that case is guarded HERE.
//
// A version bump can still be deferred for a DIFFERENT reason — see
// filterUnsafeVersionBumpDetaches below, applied UNCONDITIONALLY (not just
// on a self-hosted node) alongside this one: this function only ever asks
// "is this a removal or a bump", never "will the bump's new digest actually
// attach" — that second question is J1's (review round 5), and answering it
// requires actually running the new manifest's security-policy decision,
// which this function has no reason to do.
func (r *Reconciler) filterUnsafeDetaches(toDetach, toAttach mount.ModuleStack, manifests map[string]*manifest.Manifest) mount.ModuleStack {
	if len(toDetach) == 0 || !r.selfHosted() {
		return toDetach
	}

	replaced := make(map[string]bool, len(toAttach))
	for _, m := range toAttach {
		replaced[m.ID] = true
	}

	safe := make(mount.ModuleStack, 0, len(toDetach))
	refused := make([]string, 0)
	for _, mod := range toDetach {
		if replaced[mod.ID] {
			safe = append(safe, mod) // version bump, not a removal
			continue
		}
		mf, ok := manifests[mod.ID]
		if ok && mf != nil && len(mf.Services) == 0 {
			safe = append(safe, mod)
			continue
		}
		refused = append(refused, mod.ID)
	}

	// Never refuse silently. An invisible guard is one somebody later
	// deletes while "cleaning up", and the operator needs to know the
	// composition on disk no longer matches what is running.
	if len(refused) > 0 {
		r.cfg.OnError("reconciler:self_host_detach_refused",
			fmt.Errorf("this node hosts its own platform; refusing to live-detach %d service-bearing module(s) [%s] — they will be dropped at the next recompose",
				len(refused), strings.Join(refused, ", ")))
	}
	return safe
}

// filterUnverifiedDetaches drops from a detach set any module whose manifest
// THIS TICK could not be loaded at all (see manifestFetchFailed's doc in
// RunOnce) — a distinct failure mode from the one filterUnsafeDetaches
// guards, and applied UNCONDITIONALLY (self-hosted or not).
//
// WHY UNCONDITIONAL. filterUnsafeDetaches above exists for the case where
// FetchAssignedModules itself came back degraded — see this file's doc
// comment on the 2026-07-28 incident — and only self-hosted nodes are
// unrecoverable from that. This guards a DIFFERENT input: the assigned-
// modules list is fine, but one module's manifest.LoadOrFetch call (a
// PER-MODULE, mid-tick network call) errored — e.g. the platform 502ing
// while it restarts (IMP-2dfbd7f62441, the 2026-09-22 ops-hub outage). A
// module in that state is excluded from `desired` entirely (RunOnce never
// learns its digest), so mount.Reconcile cannot distinguish "the operator
// unassigned this" from "we transiently failed to ask about it" — both look
// identical: absent from desired, present in current. Being wrong here costs
// a live service outage on ANY node, self-hosted or not (a non-self-hosted
// node recovers on its own next successful tick, but the outage in between
// is real and unnecessary), so this filter does not gate on selfHosted().
//
// A module that legitimately left the assignment list was NEVER a manifest
// fetch failure — it is simply absent from desiredModules, which never
// enters `failed`. So this can only ever make a detach MORE conservative,
// never block a real removal.
func (r *Reconciler) filterUnverifiedDetaches(toDetach mount.ModuleStack, failed map[string]bool) mount.ModuleStack {
	if len(toDetach) == 0 || len(failed) == 0 {
		return toDetach
	}

	safe := make(mount.ModuleStack, 0, len(toDetach))
	deferred := make([]string, 0)
	for _, mod := range toDetach {
		if failed[mod.ID] {
			deferred = append(deferred, mod.ID)
			continue
		}
		safe = append(safe, mod)
	}

	if len(deferred) > 0 {
		r.cfg.OnError("reconciler:detach_deferred_manifest_fetch_failed",
			fmt.Errorf("this pass could not load %d assigned module(s)' manifest(s) [%s]; deferring their detach rather than treating the fetch failure as a removal — they will be re-evaluated next tick",
				len(deferred), strings.Join(deferred, ", ")))
	}
	return safe
}

// filterUnsafeVersionBumpDetaches defers detaching a module's OLD digest, on
// a same-module-ID version bump, when the NEW digest's attach would refuse
// to (re)attach/start it (J1, review round 5 — a replacement review found
// the DIGEST-BUMP OUTAGE this task's own G1/H-series fixes had not covered).
//
// THE BUG. mount.Reconcile compares by digest, so a version bump puts the
// old digest in toDetach and the new one in toAttach. filterUnsafeDetaches
// (above) deliberately lets a version bump's detach through UNCONDITIONALLY
// — that is correct for the failure mode IT guards (a degraded
// FetchAssignedModules response misread as a removal), but it means nothing
// upstream of the detach/attach loops asks whether the new digest can
// actually attach. RunOnce runs the detach loop BEFORE the attach loop, so a
// version bump whose new digest refuses (a security drop-in write failure,
// an unapproved privileged request, or an invalid policy) detaches the OLD,
// WORKING units first and then fails to bring up the new ones — the module
// is down, on every node, until some later tick's new digest attach
// succeeds. On a SELF-HOSTED node this is worse than "down": if the module
// is ops-hub's own rails/postgres, the next tick's FetchAssignedModules call
// goes to the now-dead rails and never runs the attach loop that would have
// restored it (the same shape as the 2026-07-28 incident selfhost.go's own
// doc comment describes, reached via a different route: THAT incident lost
// the assignment entirely; this one keeps the assignment but the new
// digest's own attach refuses it). It is UNCONDITIONAL, not gated on
// selfHosted() like filterUnsafeDetaches: the outage is real on any node,
// merely unrecoverable (rather than self-correcting next tick) on one that
// hosts its own control plane.
//
// THE PRE-CHECK. Runs wouldModuleSecurityPolicyRefuse — a SIDE-EFFECT-FREE
// decision (K1, review round 6, CRITICAL) sharing decideModuleSecurityPolicy
// with the real attach path but probing writability instead of writing real
// content — against the NEW manifest, for every version-bump module, before
// either detach loop or attach loop runs. This function used to call
// applyModuleSecurityPolicy directly (J1, review round 5), which runs the
// REAL writers; because a version bump's old and new digest share the exact
// same unit name, that was silently rewriting the STILL-RUNNING old digest's
// live drop-ins with the NEW digest's content on every tick a bump was
// deferred (K1's own finding — see wouldModuleSecurityPolicyRefuse's doc for
// the full story). If the pre-check refuses, the old digest is left OUT of
// the returned (safe-to-detach) set: the currently-running units keep
// running under their previous, already-applied confinement, exactly the
// posture attachModule's own drop-in-failure branch already accepts for a
// live re-attach — and, since K1, ACTUALLY still their previous confinement,
// not a partially-applied new one. toAttach is NOT modified — the real
// attach loop still runs attachModule for the new digest and gets the SAME
// refusal, which is what actually calls recordSecurityFailClosed and marks
// the pass unconverged; this function's job is only to keep the old digest
// attached while that happens, never to suppress or duplicate that
// reporting.
//
// A module with NO fresh manifest for its new digest at all is treated the
// same as a refusal (deferred, not detached) — RunOnce's own attach loop
// already refuses a toAttach entry with no loaded manifest
// (reconciler:missing_manifest) without ever reaching a security decision,
// and detaching the old digest ahead of a new one that cannot even be
// inspected would be strictly worse than that existing refusal.
//
// K2a (review round 6, CRITICAL): the security-policy pre-check is not the
// only way a version bump's new digest can fail to attach — an artifact
// pull/verify/mount failure (a bad blob, a cosign/fs-verity mismatch, a
// mid-tick ENOSPC) is invisible to it, since wouldModuleSecurityPolicyRefuse
// never touches the module's mounted content at all. artifactReady (from
// prefetchNewArtifacts, called earlier this same tick) is consulted FIRST,
// before the security pre-check even runs — an artifact that never even
// mounted has no drop-in units worth probing.
//
// versionBumpDeferral (the return type) reports enough for the CALLER
// (RunOnce) to do two more things this function deliberately does NOT do
// itself: skip the deferred module's new digest in the attach loop entirely
// this tick (K3 — this function only decides the DETACH side; RunOnce owns
// toAttach) and record any drop-in units the security pre-check actually
// found failing, the same way a real attach would have (this function only
// EMITS the human-readable OnError summary below; it must not itself call
// recordSecurityFailClosed, which RunOnce's securityPolicyAttemptedUnits
// bookkeeping — J3 — needs to stay coupled to the SAME call site as every
// other recordSecurityFailClosed call).
type versionBumpDeferral struct {
	moduleID    string
	failedUnits []string // non-nil only for an actual drop-in-probe refusal — nil for privileged-unapproved/invalid-policy/artifact-not-ready, exactly mirroring attachModule's own recordSecurityFailClosed gating
}

func (r *Reconciler) filterUnsafeVersionBumpDetaches(toDetach, toAttach mount.ModuleStack, manifests map[string]*manifest.Manifest, artifactReady map[string]bool, failedBumps map[string]string) (safe mount.ModuleStack, deferrals []versionBumpDeferral) {
	if len(toDetach) == 0 {
		return toDetach, nil
	}

	newByID := make(map[string]mount.Module, len(toAttach))
	for _, m := range toAttach {
		newByID[m.ID] = m
	}

	safe = make(mount.ModuleStack, 0, len(toDetach))
	deferredIDs := make([]string, 0)
	persistentlyFailedIDs := make([]string, 0)
	for _, mod := range toDetach {
		newMod, isBump := newByID[mod.ID]
		if !isBump {
			safe = append(safe, mod) // not a version bump — nothing for this guard to say
			continue
		}
		// L2 part 1 (review round 7, HIGH): this EXACT digest already failed
		// its real attach after a detach on some earlier tick — a failure
		// mode the pre-check below could not predict (see
		// versionBumpDeferral's own doc and reconcile.go's FailedVersionBumps
		// write site for the full story). Deferred here, BEFORE even the
		// artifact-readiness check, without touching artifactReady or
		// running the pre-check again: repeating either would cost real work
		// (a pull/mount or a drop-in probe) for a digest already known, from
		// this node's own history, not to attach — and neither check is what
		// found THIS failure in the first place, so re-running them teaches
		// nothing new. A genuinely NEW third digest for the same module
		// naturally bypasses this: the map compares by digest, not by
		// module ID alone.
		if failedDigest, known := failedBumps[mod.ID]; known && failedDigest == newMod.Digest {
			persistentlyFailedIDs = append(persistentlyFailedIDs, mod.ID)
			var failedUnits []string
			if mf, ok := manifests[mod.ID]; ok && mf != nil {
				failedUnits = mf.UnitNames()
			}
			deferrals = append(deferrals, versionBumpDeferral{moduleID: mod.ID, failedUnits: failedUnits})
			continue
		}
		if !artifactReady[mod.ID] {
			deferredIDs = append(deferredIDs, mod.ID)
			deferrals = append(deferrals, versionBumpDeferral{moduleID: mod.ID})
			continue
		}
		mf, ok := manifests[mod.ID]
		if !ok || mf == nil {
			deferredIDs = append(deferredIDs, mod.ID)
			deferrals = append(deferrals, versionBumpDeferral{moduleID: mod.ID})
			continue
		}
		failedUnits, err := r.wouldModuleSecurityPolicyRefuse(newMod, mf)
		if err != nil {
			deferredIDs = append(deferredIDs, mod.ID)
			deferrals = append(deferrals, versionBumpDeferral{moduleID: mod.ID})
			continue
		}
		if len(failedUnits) > 0 {
			deferredIDs = append(deferredIDs, mod.ID)
			deferrals = append(deferrals, versionBumpDeferral{moduleID: mod.ID, failedUnits: failedUnits})
			continue
		}
		safe = append(safe, mod)
	}

	if len(deferredIDs) > 0 {
		r.cfg.OnError("reconciler:version_bump_detach_deferred_would_fail_closed",
			fmt.Errorf("this tick's version bump for %d module(s) [%s] would refuse to (re)attach its new digest (artifact not ready, invalid policy, or a security drop-in write); keeping the currently-running (old digest) units in place instead of detaching them first — they will be re-evaluated next tick",
				len(deferredIDs), strings.Join(deferredIDs, ", ")))
	}
	// L2 part 1: a separate, distinct diagnostic from the one above — this
	// case was NOT decided by anything this tick observed at all, but by a
	// PAST tick's real attach failure remembered in FailedVersionBumps.
	// Worth its own message: an operator reading only the generic message
	// above would look for what THIS tick's pre-check found and find
	// nothing, since nothing here ran.
	if len(persistentlyFailedIDs) > 0 {
		r.cfg.OnError("reconciler:version_bump_detach_deferred_previously_failed",
			fmt.Errorf("this tick's version bump for %d module(s) [%s] targets a digest that ALREADY failed its real attach after a detach on an earlier tick (see reconciler:version_bump_real_attach_failed_recorded); deferring indefinitely without re-detaching — will retry automatically only if a NEW digest is proposed, or an operator can force a retry via a manual attach",
				len(persistentlyFailedIDs), strings.Join(persistentlyFailedIDs, ", ")))
	}
	return safe, deferrals
}
