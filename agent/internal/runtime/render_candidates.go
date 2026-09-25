package runtime

import (
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// renderCandidates is the manifest set the identity/sudoers/egress render is
// built from, and how each member was resolved. Extracted from RunOnce so the
// boot state rebase (state_rebase.go) can compute a drop's render impact from
// the render's OWN set rather than a re-implementation of it.
type renderCandidates struct {
	merged map[string]*manifest.Manifest
	// retainedNotFresh are retained modules with no fresh manifest this tick:
	// the hot-prune layer resolution must still see them (review finding N3).
	retainedNotFresh                                                      []mount.Module
	staleFallback, breadcrumbFallback, unresolvedHarmless, unresolvedReal []string
}

// resolveRenderCandidates builds the render's manifest set from this tick's
// fresh manifests, the modules still attached (retained), the modules whose
// fetch failed, and the current boot's breadcrumb.
//
// breadcrumbManifests/breadcrumbIDs/breadcrumbDataIDs: the fallback of
// last resort — see loadBreadcrumbManifests. Needed for review finding
// R2-B1 route (2): on the first reconcile tick after state.json is empty
// (e.g. a reprovisioned /persist, or simply the first post-boot tick),
// `retained` is empty even though the live union already has real
// users rendered into it from the boot compose — a module whose
// manifest fetch fails on THAT tick must still resolve through the
// breadcrumb, or its already-live users would read as "never rendered"
// and get silently omitted.
func (r *Reconciler) resolveRenderCandidates(freshManifests map[string]*manifest.Manifest, retained []mount.Module, fetchFailed map[string]bool,
	breadcrumbManifests map[string]*manifest.Manifest, breadcrumbIDs, breadcrumbDataIDs map[string]bool) renderCandidates {
	retainedByID := make(map[string]mount.Module, len(retained))
	for _, m := range retained {
		retainedByID[m.ID] = m
	}
	manifestFetchFailed := fetchFailed

	// candidateIDs is the UNION of retained, manifestFetchFailed, AND every
	// data-bearing module the CURRENT boot's breadcrumb lists (review
	// finding round-4 #1): the first two alone still miss a module that is
	// genuinely running — composed at boot into the live union — but is
	// absent from BOTH state.json (never persisted, or lost) AND this
	// tick's assigned-modules list (omitted, or a degraded response) at the
	// SAME time, so it never becomes "retained" (state never named it) and
	// never becomes "fetch-failed" (it was never even attempted — absent
	// from desiredModules entirely). Without this, such a module's users
	// would be dropped from the render with no signal at all, having gone
	// through neither the "resolved" nor the "explicitly unresolved" path.
	// `retained` alone misses route (2) above (a fetch failure on an
	// empty-state tick is never "retained"), and manifestFetchFailed alone
	// misses a module that stays attached but was never even asked about
	// this tick (omitted from the assigned list; self-hosted refusal).
	candidateIDs := make(map[string]bool, len(retainedByID)+len(manifestFetchFailed)+len(breadcrumbDataIDs))
	for id := range retainedByID {
		candidateIDs[id] = true
	}
	for id := range manifestFetchFailed {
		candidateIDs[id] = true
	}
	for id := range breadcrumbDataIDs {
		candidateIDs[id] = true
	}

	// mergedManifests unions this tick's FRESH manifests with, for every
	// candidate module that has none, the best available fallback (the
	// resolution loop below). desiredForLayers extends `desired` with every
	// RETAINED-but-not-fresh module's CURRENTLY ATTACHED Digest/Priority
	// (never the manifest — mount.ModuleMountPath only needs those): the
	// hot-prune layer functions (higherPriorityLayerDirs, survivingLayerDirs,
	// processPendingPrunes below) must see a module that is genuinely still
	// mounted regardless of whether its manifest resolved this tick (review
	// finding N3) — otherwise a REAL leaver's prune could delete a path this
	// retained module still provides, reading its silence as "nobody else
	// has this". A retained-but-not-fresh module that turns out to be
	// UNMOUNTED is not a new risk introduced by this: the existing
	// layerProvidesAnything check inside processPendingPrunes and
	// hotReconcileIfNeeded's prune call already defers the WHOLE prune pass
	// rather than resolve surviving-layer claims against a layer that isn't
	// actually serving content (review finding N4) — this only widens the
	// set that check inspects, never bypasses it.
	mergedManifests := make(map[string]*manifest.Manifest, len(freshManifests)+len(candidateIDs))
	for id, m := range freshManifests {
		mergedManifests[id] = m
	}
	var retainedNotFresh []mount.Module

	// Resolution loop — review finding R2-B1. For each candidate without a
	// fresh manifest: try the on-disk cache, then the boot breadcrumb, in
	// that order. A RETAINED module's currently-mounted Digest is the ground
	// truth of what is actually running; a fallback manifest whose OWN
	// Digest disagrees with it describes a DIFFERENT version and must not be
	// used (review finding N2) — it is exactly as unresolved as no fallback
	// at all, and the other source is tried before giving up. A candidate in
	// manifestFetchFailed but NOT retained (route (2) above) has no expected
	// digest to check a fallback against, so any resolved source is
	// accepted.
	//
	// A candidate that resolves via NEITHER cache NOR breadcrumb is safe to
	// silently OMIT from the render (as if it declared nothing) only when it
	// was NEVER real: not retained, and not in the breadcrumb's module list
	// either — a genuinely new module whose first-ever fetch failed, which
	// by construction was never part of any render this agent has produced.
	// Any OTHER unresolved candidate — retained, or present in the
	// breadcrumb (compose already rendered it into the live union even
	// though this tick's "what's attached" bookkeeping was separately lost)
	// — is one this agent's OWN render history says is real, and rendering
	// without it would repeat the exact partial-view mistake the 2026-09-22
	// outage made. In that case the ENTIRE identity/sudoers/egress render
	// for this tick is SKIPPED (round-1 behaviour, restored for this one
	// case), leaving whatever the last resolvable tick wrote in place, which
	// is always at least as correct as a render known to be missing a real
	// module. This cannot re-freeze the render forever the way the old
	// blanket skip did: it fires only when a module that IS real resolves
	// via none of three independent sources simultaneously, not merely
	// because ONE tick's fetch failed.
	var staleFallback, breadcrumbFallback, unresolvedHarmless, unresolvedReal []string
	for id := range candidateIDs {
		if _, fresh := mergedManifests[id]; fresh {
			continue
		}
		retainedMod, isRetained := retainedByID[id]
		if isRetained {
			retainedNotFresh = append(retainedNotFresh, retainedMod)
		}
		var expectedDigest string
		hasExpected := false
		if isRetained {
			expectedDigest, hasExpected = retainedMod.Digest, true
		}

		resolved := false
		if cached, cerr := manifest.LoadFromDisk(r.cfg.ManifestRoot, id); cerr == nil && cached != nil {
			if !hasExpected || cached.Digest == expectedDigest {
				mergedManifests[id] = cached
				staleFallback = append(staleFallback, id)
				resolved = true
			}
		}
		if !resolved {
			if bm, ok := breadcrumbManifests[id]; ok && (!hasExpected || bm.Digest == expectedDigest) {
				mergedManifests[id] = bm
				breadcrumbFallback = append(breadcrumbFallback, id)
				resolved = true
			}
		}
		if resolved {
			continue
		}

		if isRetained || breadcrumbIDs[id] {
			unresolvedReal = append(unresolvedReal, id)
		} else {
			unresolvedHarmless = append(unresolvedHarmless, id)
		}
	}
	return renderCandidates{
		merged:             mergedManifests,
		retainedNotFresh:   retainedNotFresh,
		staleFallback:      staleFallback,
		breadcrumbFallback: breadcrumbFallback,
		unresolvedHarmless: unresolvedHarmless,
		unresolvedReal:     unresolvedReal,
	}
}
