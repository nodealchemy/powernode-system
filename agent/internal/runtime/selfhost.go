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

// selfHostState is the tri-state self-hosting probe result (round Y,
// IMP-caef5c00d63f — N2 from the round-X confirm review). The pre-round-Y
// selfHosted() collapsed every probe failure (DNS error, interface-list
// error, an unparsable PlatformURL) to `false` ("not self-hosted, safe to
// restart") — the SAME answer a genuine remote node gives. On a
// self-hosted node's own first tick after a transient resolver hiccup,
// that meant "restart this node's own control-plane unit", the exact
// outage class this whole guard exists to prevent, before the latch ever
// had a chance to arm. selfHostUnknown separates "we could not tell" from
// "we positively confirmed this is not us", so a caller deciding whether a
// restart is safe (restartPermitted, below) can treat unknown the same as
// self-hosted rather than the same as remote.
type selfHostState int

const (
	selfHostUnknown selfHostState = iota
	selfHostNo
	selfHostYes
)

// selfHostState resolves the tri-state. The Yes answer LATCHES once
// reached and is never recomputed — DNS is frequently the first casualty
// of the kind of degradation this guard exists for, and re-probing on
// every tick would let a resolver blip disarm the protection at precisely
// the wrong moment. Latching only toward Yes (never Yes-to-No or
// Yes-to-Unknown) means the worst a flaky probe can do afterward is
// nothing — once armed, it stays armed.
func (r *Reconciler) selfHostState() selfHostState {
	r.selfHostMu.Lock()
	defer r.selfHostMu.Unlock()
	if r.selfHostLatched {
		return selfHostYes
	}
	if r.cfg.PlatformURL == "" {
		// No platform configured at all means no self-hosting is even
		// possible — a definite No, not an Unknown withholding restarts
		// for no reason. UNCHANGED by round Z: Z2's own empty-PlatformURL
		// caveat is scoped to restartPermitted's OWN decision only (see
		// that function's doc) — selfHosted()/filterUnsafeDetaches keep
		// this exact pre-Z2 reading, so an unconfigured node's detach
		// behaviour is untouched by Z2.
		return selfHostNo
	}

	host := hostFromURL(r.cfg.PlatformURL)
	if host == "" {
		return selfHostUnknown
	}
	platformIPs, err := lookupHostIPs(host)
	if err != nil || len(platformIPs) == 0 {
		return selfHostUnknown
	}
	locals, err := localInterfaceIPs()
	if err != nil {
		return selfHostUnknown
	}
	localSet := make(map[string]bool, len(locals))
	for _, l := range locals {
		localSet[strings.TrimSpace(l)] = true
	}
	for _, p := range platformIPs {
		if localSet[strings.TrimSpace(p)] {
			r.selfHostLatched = true
			return selfHostYes
		}
	}
	return selfHostNo
}

// selfHosted reports whether cfg.PlatformURL points at THIS node, for
// callers that only need the CONSERVATIVE (defer-if-unsure) reading —
// filterUnsafeDetaches' own detach fence, where treating Unknown the same
// as Yes only ever costs a deferred, next-tick-retried detach, never an
// unrecoverable one. Callers deciding whether a RESTART is safe must use
// restartPermitted instead — a restart withheld under Unknown costs
// nothing durable, but one issued under Unknown could be the same
// self-inflicted outage class N2 exists to close.
func (r *Reconciler) selfHosted() bool {
	return r.selfHostState() != selfHostNo
}

// hubModuleNames (round Z, Z2) is the pinned control-plane identity check —
// the same approach as qgaModuleName (security_dropins.go's own recovery-
// channel pin): the agent has no other reliable per-module identity signal
// today, so this is matched by NAME from the manifest, and publishing a
// signed module under one of these exact names to the shared catalog is
// itself a privileged, server-gated action, so an arbitrary untrusted
// manifest cannot simply declare its way into one.
//
// TODO(server): deliver a proper allowlist/exemption field from the
// platform instead of pinning by name — this is the interim fix, same
// caveat as qgaModuleName's own TODO.
var hubModuleNames = map[string]bool{
	"powernode-hub-backend":      true,
	"powernode-hub-worker":       true,
	"powernode-extension-system": true,
}

// hostsControlPlaneModule reports whether attached names ANY pinned
// control-plane module (round Z, Z2) — FAIL SAFE: a module this tick could
// not resolve a manifest for, or one whose manifest carries no Name at all,
// counts AS a control-plane module. This is a POSITIVE PROOF requirement,
// not an absence-of-evidence one: restartPermitted (below) must be able to
// point at a resolved, non-hub name for EVERY attached module before it can
// conclude this node does not host the control plane — it is not enough
// that nothing LOOKS like a hub module.
func hostsControlPlaneModule(attached []mount.Module, manifests map[string]*manifest.Manifest) bool {
	for _, mod := range attached {
		mf, ok := manifests[mod.ID]
		if !ok || mf == nil || mf.Name == "" {
			return true
		}
		if hubModuleNames[mf.Name] {
			return true
		}
	}
	return false
}

// restartPermitted reports whether a live restart is safe to issue at all
// (round Y, extended round Z Z2). ALL of the following must hold:
//
//  1. cfg.PlatformURL is non-empty. Scoped to THIS function only — an
//     unconfigured PlatformURL still reads as selfHostState()==No for
//     every OTHER caller (selfHosted(), filterUnsafeDetaches): widening
//     that would be scope creep for what this round is about, and every
//     real production agent has a PlatformURL configured regardless. But
//     restartPermitted's own bar is stricter by design (Z2's positive-proof
//     requirement, point 3 below) — an agent that was never TOLD its
//     platform's address has no basis to positively conclude it is safe to
//     restart one of its own units, so this one caller alone refuses on
//     empty rather than falling through to selfHostState's own No default.
//  2. selfHostState() == No: Unknown is treated the SAME as Yes (never
//     permit), closing N2 — see selfHostState's own doc for the outage
//     that treating it like a remote node caused.
//  3. r.hostsControlPlaneModule is false: a POSITIVE, per-tick proof (set
//     once per RunOnce pass from hostsControlPlaneModule, above) that NONE
//     of this node's currently attached modules resolves to a pinned
//     control-plane name. DNS/interface resolution alone was never a
//     complete proxy for "this node does not host the control plane" — a
//     node can host the hub while its own PlatformURL happens to resolve
//     to a different local address (a load balancer, a second interface),
//     or before DNS the operator meant to point at itself is even wired
//     up. This is the independent, local signal that does not depend on
//     resolving anything over the network at all.
//
// Every restart site in this package (R1's ConfinementChangedUnits-driven
// restart is the only one left — R2's level self-heal was deleted in round
// Z Z1) must gate on this, never on `!selfHosted()` directly.
func (r *Reconciler) restartPermitted() bool {
	if r.cfg.PlatformURL == "" {
		return false
	}
	return r.selfHostState() == selfHostNo && !r.hostsControlPlaneModule
}

// filterUnsafeDetaches drops service-bearing modules from a detach set when
// this node hosts the platform it reconciles against. Returns the stack that
// is safe to detach live.
//
// A module with no manifest is treated as service-bearing: absence of proof
// is not proof of absence, and on a self-hosted node being wrong is
// unrecoverable while being over-cautious costs only a deferred removal.
//
// NOTE (round 9): this used to also carry a "version bump is not a removal"
// branch, since mount.Reconcile compares by digest and put a bump's OLD
// digest in toDetach alongside its NEW digest in toAttach. As of the
// round-9 in-place-upgrade redesign, RunOnce itself partitions a version
// bump's old/new pair OUT of toDetach/toAttach before either ever reaches
// this function (see RunOnce's own doc on that split) — a bump is handled
// entirely by the new upgrade path, never by detach-then-attach. Every
// module this function now sees in toDetach is therefore a genuine
// REMOVAL (no same-ID successor), and the self-host fence applies to it
// unconditionally.
func (r *Reconciler) filterUnsafeDetaches(toDetach, toAttach mount.ModuleStack, manifests map[string]*manifest.Manifest) mount.ModuleStack {
	if len(toDetach) == 0 || !r.selfHosted() {
		return toDetach
	}

	safe := make(mount.ModuleStack, 0, len(toDetach))
	refused := make([]string, 0)
	for _, mod := range toDetach {
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
