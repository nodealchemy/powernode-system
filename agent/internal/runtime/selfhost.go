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
// A VERSION BUMP IS NOT A REMOVAL and must pass through untouched. The old
// digest lands in toDetach and the new one in toAttach, so refusing that
// detach would leave both versions attached at once and break upgrades on
// exactly the node that most needs to receive them. An upgrade is also
// self-correcting in a way a removal is not: the replacement immediately
// re-provides the same services. Only a module with no same-ID successor is
// genuinely leaving, and only that case is guarded.
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
