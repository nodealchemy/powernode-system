// manager.go — orchestrates the per-tick SDWAN reconcile loop.
//
// Slice 1 flow:
//
//   Reconcile() →
//     1. GET /node_api/config/sdwan       (DesiredConfig)
//     2. For each desired network:
//          a. ApplyInterface via WgApplier (idempotent)
//          b. ReadActualState              (handshake / bytes / endpoint)
//     3. POST /node_api/status/sdwan       (PeerStatusReport batch)
//     4. Update LastReconcile state for the heartbeat reporter
//
// Drift handling (orphan interfaces): any wg-sdwan-* interface NOT in
// the desired set is removed. This is the simplest correct
// implementation — it ensures the kernel's view never lags the
// platform's view by more than one tick.
//
// Slice 1 of the SDWAN plan.

package sdwan

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// Manager owns the reconcile loop. One per agent process.
type Manager struct {
	Client          *transport.Client
	Applier         WgApplier
	NftablesApplier NftablesApplier
	NatApplier      NatApplier
	VipApplier      VipApplier
	FrrApplier      FrrApplier
	FrrObserver     FrrObserver
	// Phase N1a: VRF master device manager. Runs BEFORE the per-network
	// loop so each WG iface has its target VRF ready at creation time.
	VRFApplier VRFApplier
	// Phase O1+O2: host-side bridge managers. Runs BEFORE the per-network
	// loop so any bridge a libvirt domain expects to attach a tap iface
	// to exists by the time the WG iface is created.
	//
	// Slice rather than single applier because the strategy partition is
	// by DesiredBridge.Kind: LinuxBridgeApplier handles `linux`-kind
	// bridges, OvsBridgeApplier handles `ovs`-kind. Both always run; each
	// filters by Kind. The platform compiler stamps Kind per host based
	// on the host's network_profile (lightweight = linux-only payload,
	// heavyweight = ovs-only payload), so on lightweight hosts the OVS
	// applier is a no-op (and ovs-vsctl need not even be installed).
	BridgeAppliers []BridgeApplier
	// Phase O3: per-host OVN-controller daemon + OVS encap-config
	// manager. nil-tolerant — lightweight hosts get a nil
	// DesiredOvnControl and the applier short-circuits without
	// touching OVS or systemctl.
	OvnControllerApplier OvnControllerApplier
	// Phase 3b-2: OVN Northbound plan applier. nil-tolerant — a nil
	// DesiredConfig.OvnNbPlan (lightweight hosts, and heavyweight hosts
	// whose account has no active deployment) makes the applier
	// short-circuit without touching ovn-nbctl. The platform's
	// topology compiler serves the SAME compiled NB plan to EVERY
	// heavyweight host with an active deployment (not just one elected
	// control host); each host replays it into the central NB DB.
	// Convergence relies on the ovn-nbctl `--may-exist` idempotency
	// plus the applier's last-signature cache, so concurrent replays
	// from multiple hosts are safe and steady-state ticks no-op.
	OvnNbApplier OvnNbApplier
	// Phase N0: per-(peer, network) MC cache + Ed25519 trust store.
	// The forwarding gate refuses to bring up tunnels without a valid
	// cached MC.
	MCVerifier *MCVerifier
	OnError    func(string, error)

	mu              sync.Mutex
	lastReconcileAt time.Time
	// subsystems holds one outcome per applier subsystem, keyed by the
	// exact label recordError/step is called with. An entry persists
	// until that same label is recorded again — a failure is only ever
	// cleared by that subsystem's own success. Guarded by mu.
	subsystems map[string]subsystemOutcome
	// healthyPeers is the measured healthy-peer count per network id,
	// rebuilt from scratch on every reconcile pass. A network absent
	// from the map was NOT measured this pass. Guarded by mu.
	healthyPeers map[string]int
	lastDesired  *DesiredConfig
	// lastOvnNbState holds the observed result of the most recent NB
	// plan replay (Phase 3b-2). nil on hosts that aren't the OVN control
	// host. Snapshot-read by OvnNbStatus for the heartbeat block.
	lastOvnNbState *ObservedOvnNbState
}

func NewManager(client *transport.Client, applier WgApplier, onError func(string, error)) *Manager {
	if applier == nil {
		applier = NewShellApplier()
	}
	if onError == nil {
		onError = func(_ string, _ error) {}
	}
	return &Manager{
		Client:          client,
		Applier:         applier,
		NftablesApplier: NewShellNftablesApplier(),
		NatApplier:      NewShellNatApplier(),
		VipApplier:      NewShellVipApplier(),
		FrrApplier:      NewShellFrrApplier(),
		FrrObserver:     NewShellFrrObserver(),
		VRFApplier:      NewShellVRFApplier(),
		BridgeAppliers: []BridgeApplier{
			NewLinuxBridgeApplier(),
			NewOvsBridgeApplier(),
		},
		OvnControllerApplier: NewOvnControllerApplier(),
		OvnNbApplier:         NewShellOvnNbApplier(),
		MCVerifier:           NewMCVerifier(),
		OnError:              onError,
	}
}

// Reconcile fetches desired state, applies it, and reports observed state.
// Designed to be called from Heartbeater.PostSend on every tick.
//
// Errors are surfaced via OnError; the function itself never returns an
// error so a transient SDWAN failure can't kill the heartbeat goroutine.
func (m *Manager) Reconcile(ctx context.Context) {
	desired, err := m.fetchDesiredConfig(ctx)
	if err != nil {
		m.recordError("fetch_desired_config", err)
		return
	}
	m.recordSuccess("fetch_desired_config")

	// Phase N0: trust every constellation pubkey the controller advertises.
	// Idempotent; re-trusting an existing handle is a no-op.
	if m.MCVerifier != nil {
		for _, c := range desired.Constellations {
			_ = m.step("trust_constellation:"+c.Handle, func() error {
				return m.MCVerifier.TrustConstellation(c.Handle, c.PublicKeyB64)
			})
		}
	}

	// Phase N1a: ensure all per-host VRF master devices exist BEFORE the
	// per-network loop runs — wg_applier needs the VRF to bind interfaces
	// to. Errors are recorded but don't abort the loop; per-network
	// applies will fail individually if their VRF is missing.
	if m.VRFApplier != nil {
		_ = m.step("apply_vrfs", func() error {
			return m.VRFApplier.Apply(ctx, desired.VrfAssignments)
		})
	}

	// Phase O1+O2: ensure all host-side bridges exist BEFORE the
	// per-network loop runs. Errors are recorded but don't abort the
	// loop; per-bridge failures are best-effort (e.g. a bridge with
	// attached tap interfaces can't be deleted, but the next reconcile
	// after detach will succeed). Each registered BridgeApplier filters
	// by DesiredBridge.Kind, so iterating the full slice with the full
	// payload is safe — they partition the work, never duplicate it.
	for i, applier := range m.BridgeAppliers {
		if applier == nil {
			continue
		}
		_ = m.step(fmt.Sprintf("apply_bridges[%d]", i), func() error {
			return applier.Apply(ctx, desired.HostBridges)
		})
	}

	// Phase O3: align local ovn-controller state with the per-host
	// intent. nil DesiredConfig.OvnControl means lightweight host or
	// no OVN deployment — the applier no-ops without touching OVS or
	// systemctl. Errors are recorded but don't abort the loop.
	// Runs AFTER bridges (ovn-controller programs flows into OVS, so
	// OVS must be initialized) and BEFORE the per-network loop (so
	// the daemon is ready when traffic starts flowing).
	if m.OvnControllerApplier != nil {
		_ = m.step("apply_ovn_control", func() error {
			return m.OvnControllerApplier.Apply(ctx, desired.OvnControl)
		})
	}

	// Phase 3b-2: replay the compiled OVN Northbound plan into the
	// central NB DB. A nil DesiredConfig.OvnNbPlan means this host has
	// no NB plan to apply (lightweight host, or no active deployment on
	// the account) — the applier no-ops without touching ovn-nbctl.
	// Every heavyweight host with an active deployment receives the same
	// compiled plan and replays it; there is no single elected control
	// host. That is safe because each ovn-nbctl command is issued with
	// `--may-exist` (server-side idempotency) and the applier caches the
	// last-applied signature, so redundant replays from multiple hosts
	// converge on the same NB state. Runs AFTER the ovn-controller
	// applier (which ensures the local chassis is registered) and BEFORE
	// the per-network loop. The observed result is stashed for the
	// heartbeat so the platform sees how far the replay got. A replay
	// error is recorded but never aborts the loop — the next tick
	// re-attempts the full (idempotent) plan.
	if m.OvnNbApplier != nil {
		// Apply is called even for a nil/empty plan: that path is how the
		// applier resets its last-endpoint/last-signature cache, so
		// skipping the call would strand stale replay state.
		obs, err := m.OvnNbApplier.Apply(ctx, desired.OvnNbPlan)
		switch {
		case err != nil:
			m.recordError("apply_ovn_nb_plan", err)
		case desired.OvnNbPlan == nil || len(desired.OvnNbPlan.Plan) == 0:
			// The applier's nil/empty-plan branch returns nil having
			// executed nothing — it is a precondition-absent no-op, not
			// an observed success. Reporting "ok" here would tell every
			// lightweight host, and every heavyweight host with no active
			// deployment, that a subsystem it never ran is healthy.
			m.forget("apply_ovn_nb_plan")
		default:
			m.recordSuccess("apply_ovn_nb_plan")
		}
		m.mu.Lock()
		m.lastOvnNbState = obs
		m.mu.Unlock()
	}

	// Build the desired-interface set so we can identify orphans below.
	desiredNames := make(map[string]struct{}, len(desired.Networks))
	for _, n := range desired.Networks {
		desiredNames[n.Interface.Name] = struct{}{}
	}

	// Apply each desired network. We continue on per-network error so a
	// single bad network doesn't block the others.
	var reports []PeerStatusReport
	// Rebuilt from scratch each pass: a network we never got as far as
	// reading is simply absent, which the heartbeat renders as
	// `healthy_peers: null` (NOT MEASURED) rather than a healthy-looking 0.
	healthy := make(map[string]int, len(desired.Networks))
	for _, net := range desired.Networks {
		// Phase N0 forwarding gate: no MC, or invalid MC, means we tear
		// down any existing interface and skip apply for this tick. The
		// next config push from the controller will carry a fresh MC.
		if m.MCVerifier != nil {
			if net.MC == nil {
				m.recordError("mc_missing:"+net.NetworkID, fmt.Errorf("no MC envelope in config push for peer %s", net.PeerID))
				_ = m.Applier.RemoveInterface(ctx, net.Interface.Name)
				m.MCVerifier.Forget(net.PeerID, net.NetworkID)
				// There is no envelope to validate, so any earlier
				// mc_validate verdict is about a credential that is gone.
				m.forget("mc_validate:" + net.NetworkID)
				continue
			}
			// The envelope is present, so the "no MC in this push" fault
			// is no longer being observed. Drop it rather than reporting
			// it as a success — mc_validate below is what actually
			// measures MC health.
			m.forget("mc_missing:" + net.NetworkID)
			if err := m.step("mc_validate:"+net.NetworkID, func() error {
				_, err := m.MCVerifier.Validate(net.PeerID, net.NetworkID, net.MC, time.Now())
				return err
			}); err != nil {
				_ = m.Applier.RemoveInterface(ctx, net.Interface.Name)
				continue
			}
		}

		// Scoped by interface name like its siblings below: the bare
		// label was shared by every network in the loop, so one
		// network's successful lookup would have cleared another's
		// failure.
		privateKey, err := m.privateKeyFor(net)
		if err != nil {
			m.recordError("private_key_lookup:"+net.Interface.Name, err)
			continue
		}
		m.recordSuccess("private_key_lookup:" + net.Interface.Name)

		if err := m.step("apply_interface:"+net.Interface.Name, func() error {
			return m.Applier.ApplyInterface(ctx, net.Interface, net.Peers, privateKey)
		}); err != nil {
			continue
		}

		// Apply the firewall ruleset AFTER the wg interface is up — the
		// nft script references the interface by name (`iif "wg-sdwan-..."`),
		// so attempting to install rules before the interface exists works
		// (nft tolerates non-existent iif names) but the rules wouldn't
		// match anything until the interface comes up. Order this way so
		// each tick converges to a known-good state on the first apply.
		if m.NftablesApplier != nil {
			if net.Firewall != nil {
				// Don't `continue` on failure — even if firewall failed,
				// the wg state reporting below is still meaningful for
				// operator triage.
				_ = m.step("apply_firewall:"+net.NetworkID, func() error {
					return m.NftablesApplier.ApplyRuleset(ctx, net.NetworkID, net.Firewall)
				})
			} else {
				// No compiled ruleset for this network any more: the
				// subsystem has nothing to converge, so its last outcome
				// stops being an answer about the present.
				m.forget("apply_firewall:" + net.NetworkID)
			}
		}

		// Slice 7b — apply NAT chain (DNAT for hub-published services).
		// Empty NatConf.Ruleset is the signal to tear down the chain;
		// the applier handles that path internally.
		if m.NatApplier != nil {
			if net.Nat != nil {
				_ = m.step("apply_nat:"+net.NetworkID, func() error {
					return m.NatApplier.ApplyRuleset(ctx, net.NetworkID, net.Nat)
				})
			} else {
				m.forget("apply_nat:" + net.NetworkID)
			}
		}

		var actual *ActualInterfaceState
		if err := m.step("read_actual:"+net.Interface.Name, func() error {
			var err error
			actual, err = m.Applier.ReadActualState(ctx, net.Interface.Name)
			return err
		}); err != nil {
			continue
		}

		netReports := peerReportsFromActual(net, actual)
		// Only networks that reach here have a MEASURED healthy count.
		healthy[net.NetworkID] = countHealthyPeers(netReports)
		reports = append(reports, netReports...)
	}

	// Reap orphan interfaces — those we have no desired config for.
	// Also tear down their nft chains so policy doesn't linger.
	if existing, err := m.Applier.ListSdwanInterfaces(ctx); err == nil {
		for _, name := range existing {
			if _, want := desiredNames[name]; !want {
				_ = m.Applier.RemoveInterface(ctx, name)
				// Best-effort chain teardown — name carries the network's
				// 8-char short id (everything after "wg-sdwan-").
				if len(name) > len("wg-sdwan-") {
					netShort := name[len("wg-sdwan-"):]
					if m.NftablesApplier != nil {
						_ = m.NftablesApplier.RemoveChain(ctx, name, &FirewallConf{
							Table: "powernode_sdwan",
							Chain: "sdwan_" + netShort,
						})
					}
					// Slice 7b — also reap the nat chain.
					if m.NatApplier != nil {
						_ = m.NatApplier.RemoveChain(ctx, name, &NatConf{
							Table: "powernode_sdwan",
							Chain: "sdwan_nat_" + netShort,
						})
					}
				}
			}
		}
	}

	// Slice 9b — apply the union of VIPs across all networks once, after
	// per-network reconcile. Loopback is host-global; reconciling per
	// network would race the apply/remove between adjacent networks.
	if m.VipApplier != nil {
		allVips := make([]VipConf, 0)
		seen := make(map[string]struct{})
		for _, net := range desired.Networks {
			for _, v := range net.VipsHeld {
				if _, ok := seen[v.Cidr]; ok {
					continue
				}
				seen[v.Cidr] = struct{}{}
				allVips = append(allVips, v)
			}
		}
		_ = m.step("apply_vips", func() error { return m.VipApplier.ApplyVips(ctx, allVips) })
	}

	// Slice 9c — FRR is a single host-wide daemon, so exactly one config is
	// applied per host and we take it from the first iBGP-enabled network.
	//
	// That is NOT the single-network limitation the original comment here
	// described. The BgpConf the platform sends is not per-network: its
	// FrrText is rendered host-wide by Sdwan::Bgp::ConfigCompiler, which
	// emits one `router bgp <as> vrf <name>` block for EVERY VRF this host
	// holds (see render_per_vrf_bgp_blocks). Every iBGP network on the host
	// is configured by the file we write here, whichever network's BgpConf
	// carried it — they carry the same host-wide FrrText.
	//
	// IMP-2f34679b6b73: what does NOT follow from one host-wide config is
	// one host-wide observation. Each network's sessions live in its own
	// VRF, so the poll below has to name the VRF or its answer belongs to
	// no network in particular. Collect the scope alongside the id.
	var iBgpScopes []BgpObservationScope
	if m.FrrApplier != nil {
		var firstEnabled *BgpConf
		for _, net := range desired.Networks {
			if net.Bgp != nil && net.Bgp.Enabled {
				if firstEnabled == nil {
					firstEnabled = net.Bgp
				}
				iBgpScopes = append(iBgpScopes, BgpObservationScope{
					NetworkID: net.NetworkID,
					// Same VrfName the wg iface is bound to — the platform
					// stamps both from the one HostVrfAssignment row, so the
					// routing context we poll is the one this network's
					// traffic actually rides in.
					VrfName: net.Interface.VrfName,
				})
			}
		}
		// Only meaningful once the whole set is known: with a single iBGP
		// network an unscoped answer cannot be confused with another
		// network's, which is what lets a host whose VRF has not landed yet
		// keep reporting instead of going dark.
		for i := range iBgpScopes {
			iBgpScopes[i].SoleIbgpNetwork = len(iBgpScopes) == 1
		}
		// The two arms are mutually exclusive, so whichever one runs
		// forgets the other: leaving the idle arm's last outcome standing
		// would report a subsystem that is no longer being attempted.
		if firstEnabled != nil {
			m.forget("disable_frr")
			_ = m.step("apply_frr", func() error { return m.FrrApplier.ApplyConfig(ctx, firstEnabled) })
		} else {
			// No iBGP networks — disable FRR (idempotent; tolerates
			// "frr already stopped").
			m.forget("apply_frr")
			_ = m.step("disable_frr", func() error { return m.FrrApplier.DisableFrr(ctx) })
		}
	}

	// Slice 9f — observe FRR's actual session state and report to the
	// platform. Polls vtysh once and posts the result; the platform
	// upserts Sdwan::BgpSession rows so the routing dashboard reflects
	// reality, not just the desired config we shipped.
	// A network that is present but not iBGP-enabled has no BGP session to
	// observe, so any earlier observe_bgp verdict for it describes a
	// subsystem the platform has stopped asking for. The end-of-pass sweep
	// cannot catch these: the scope still names a live network, so it looks
	// current. Forget them here instead, while we still know which networks
	// are enabled.
	enabledBgp := make(map[string]struct{}, len(iBgpScopes))
	for _, scope := range iBgpScopes {
		enabledBgp[scope.NetworkID] = struct{}{}
	}
	for _, net := range desired.Networks {
		if _, on := enabledBgp[net.NetworkID]; !on {
			m.forget("observe_bgp:" + net.NetworkID)
		}
	}

	if m.FrrObserver != nil && len(iBgpScopes) > 0 {
		obsCtx, cancel := ObservationContext(ctx)
		defer cancel()
		var observations []*ObservedBgpState
		for _, scope := range iBgpScopes {
			var obs *ObservedBgpState
			if err := m.step("observe_bgp:"+scope.NetworkID, func() error {
				var err error
				obs, err = m.FrrObserver.ObserveBgp(obsCtx, scope)
				return err
			}); err != nil {
				continue
			}
			// IMP-2f34679b6b73 — an observation the observer could not
			// attribute is still POSTED (the platform records why, and an
			// operator needs to see it), but it must not stand as an `ok`
			// outcome in the heartbeat. A subsystem with no entry is NOT
			// MEASURED here, which is exactly what happened, and that state
			// is never interchangeable with "ok".
			if obs != nil && !obs.Measured {
				m.forget("observe_bgp:" + scope.NetworkID)
			}
			observations = append(observations, obs)
		}
		if len(observations) > 0 {
			_ = m.step("post_bgp_status", func() error { return m.postBgpStatusReport(ctx, observations) })
		} else {
			m.forget("post_bgp_status")
		}
	} else {
		// No observer, or iBGP disabled fleet-wide. This forget must sit
		// OUTSIDE the guard: post_bgp_status is host-global, so a failure
		// left behind here would be reported on every network forever.
		m.forget("post_bgp_status")
	}

	if len(reports) > 0 {
		_ = m.step("post_status", func() error { return m.postStatusReport(ctx, reports) })
	} else {
		m.forget("post_status")
	}

	m.mu.Lock()
	// Drop outcomes whose SUBJECT the platform has stopped sending — a
	// removed network, a de-trusted constellation. Their scope no longer
	// matches anything live, so HeartbeatStatuses would misread them as
	// host-global and report them on every surviving network; unreaped
	// they would also grow without bound, one entry per handle ever seen.
	//
	// Reaping is deliberately restricted to scope kinds the desired config
	// actually enumerates. A blanket "delete any scope not present in the
	// config" would also delete discriminators the config never contains —
	// apply_bridges[i] scopes to a slice index — silently destroying live
	// reports. So each kind is added here explicitly, and an unrecognized
	// scope is left alone.
	reapable := []struct{ previous, current map[string]struct{} }{
		{networkScopeSet(m.lastDesired), networkScopeSet(desired)},
		{constellationScopeSet(m.lastDesired), constellationScopeSet(desired)},
	}
	for label := range m.subsystems {
		_, scope := splitSubsystemLabel(label)
		if scope == "" {
			continue
		}
		for _, kind := range reapable {
			if _, was := kind.previous[scope]; !was {
				continue
			}
			if _, still := kind.current[scope]; !still {
				delete(m.subsystems, label)
			}
			break
		}
	}
	m.lastReconcileAt = time.Now()
	m.healthyPeers = healthy
	m.lastDesired = desired
	m.mu.Unlock()
}

// FirstOverlayAddress returns the /128 (without prefix length) of the
// first network the agent is a peer in. Used by sibling reconcilers
// (e.g. dockerd) that need to bind a daemon to the SDWAN overlay.
// Returns "" when no SDWAN reconcile has succeeded yet — callers should
// treat empty as "wait for the next tick" rather than fail-fast, since
// the SDWAN reconciler runs first in the PostSend ordering and will
// populate this within ~30s of agent boot.
func (m *Manager) FirstOverlayAddress() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.lastDesired == nil || len(m.lastDesired.Networks) == 0 {
		return ""
	}
	addr := m.lastDesired.Networks[0].Interface.Address
	// `address` is stored in CIDR form (`<v6>/128`); strip the prefix.
	for i := 0; i < len(addr); i++ {
		if addr[i] == '/' {
			return addr[:i]
		}
	}
	return addr
}

// HeartbeatStatuses returns the per-interface status block to embed in
// the next HeartbeatPayload. Snapshot-style — safe to call concurrently
// with Reconcile.
func (m *Manager) HeartbeatStatuses() []HeartbeatStatus {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.lastDesired == nil {
		return nil
	}

	// A scope that names one of the current networks is reported only on
	// that network. Everything else — an empty scope, or a discriminator
	// that isn't a network (a constellation handle, a bridge index) — is
	// host-global and is reported on every network, since a host-wide
	// failure is relevant to all of them.
	netScopes := networkScopeSet(m.lastDesired)

	out := make([]HeartbeatStatus, 0, len(m.lastDesired.Networks))
	for _, net := range m.lastDesired.Networks {
		st := HeartbeatStatus{
			Interface:       net.Interface.Name,
			NetworkID:       net.NetworkID,
			PeerCount:       len(net.Peers),
			LastReconcileAt: m.lastReconcileAt.UTC().Format(time.RFC3339),
		}
		if measured, ok := m.healthyPeers[net.NetworkID]; ok {
			// Copy into a fresh variable — callers must never hold a
			// pointer into manager state.
			n := measured
			st.HealthyPeers = &n
		}

		var newestFailure time.Time
		for label, o := range m.subsystems {
			subsystem, scope := splitSubsystemLabel(label)
			if _, isNetScoped := netScopes[scope]; isNetScoped {
				if scope != net.NetworkID && scope != net.Interface.Name {
					continue
				}
			}
			state := SubsystemStateOK
			if o.failed {
				state = SubsystemStateError
				if o.observedAt.After(newestFailure) {
					newestFailure = o.observedAt
					st.LastError = o.message
				}
			}
			st.SubsystemStates = append(st.SubsystemStates, SubsystemStatus{
				Subsystem:  subsystem,
				Scope:      scope,
				State:      state,
				Message:    o.message,
				ObservedAt: o.observedAt.UTC().Format(time.RFC3339),
			})
		}
		// Map iteration order is random; sort so the payload is stable
		// across ticks and a diffing consumer sees no phantom churn.
		sort.Slice(st.SubsystemStates, func(i, j int) bool {
			if st.SubsystemStates[i].Subsystem != st.SubsystemStates[j].Subsystem {
				return st.SubsystemStates[i].Subsystem < st.SubsystemStates[j].Subsystem
			}
			return st.SubsystemStates[i].Scope < st.SubsystemStates[j].Scope
		})

		out = append(out, st)
	}
	return out
}

// OvnNbStatus returns the observed result of the most recent OVN
// Northbound plan replay, or nil when no replay has run this boot
// (Phase 3b-2). Snapshot-style — safe to call concurrently with
// Reconcile. Embedded into the heartbeat as the top-level
// `sdwan_ovn_state` block (runtime.buildHeartbeat), where the
// platform's Sdwan::Ovn::DeploymentReconciler consumes it to drive
// the Sdwan::OvnDeployment lifecycle (IMP-57e9a90598ee).
func (m *Manager) OvnNbStatus() *ObservedOvnNbState {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastOvnNbState
}

// ------------------------------------------------------------------
// Internals
// ------------------------------------------------------------------

// subsystemOutcome is the stored half of SubsystemStatus. Kept unexported
// so the wire shape and the bookkeeping can evolve independently.
type subsystemOutcome struct {
	failed     bool
	message    string
	observedAt time.Time
}

// step runs one reconcile step and records its outcome under label. It is
// the only place a success is written, which keeps "record the outcome"
// from being copy-pasted across every applier call site. The error is
// returned unchanged so call sites keep their existing control flow
// (`continue` on failure, and so on).
func (m *Manager) step(label string, fn func() error) error {
	if err := fn(); err != nil {
		m.recordError(label, err)
		return err
	}
	m.recordSuccess(label)
	return nil
}

// recordError marks label as failing. The failure persists until that same
// label succeeds — no other subsystem, and no end-of-pass sweep, clears it.
func (m *Manager) recordError(label string, err error) {
	m.OnError(label, err)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.putOutcomeLocked(label, subsystemOutcome{failed: true, message: err.Error(), observedAt: time.Now()})
}

// recordSuccess marks label as having run and succeeded, clearing any
// prior failure recorded under it.
func (m *Manager) recordSuccess(label string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.putOutcomeLocked(label, subsystemOutcome{observedAt: time.Now()})
}

// forget drops label back to NOT MEASURED. Used when a subsystem does not
// run this pass because its precondition is absent from the desired config
// (a network that no longer carries a firewall, an FRR arm the other branch
// now owns) — reporting a stale outcome for something the platform has
// stopped asking for would be a lie in either direction.
func (m *Manager) forget(label string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.subsystems, label)
}

func (m *Manager) putOutcomeLocked(label string, o subsystemOutcome) {
	if m.subsystems == nil {
		m.subsystems = make(map[string]subsystemOutcome)
	}
	m.subsystems[label] = o
}

// splitSubsystemLabel separates the subsystem name from the discriminator
// the call site appended: "apply_firewall:net-abcd" → ("apply_firewall",
// "net-abcd"), "apply_bridges[1]" → ("apply_bridges", "1"), "apply_vrfs" →
// ("apply_vrfs", "").
func splitSubsystemLabel(label string) (subsystem, scope string) {
	if i := strings.IndexByte(label, ':'); i >= 0 {
		return label[:i], label[i+1:]
	}
	if strings.HasSuffix(label, "]") {
		if i := strings.IndexByte(label, '['); i >= 0 {
			return label[:i], label[i+1 : len(label)-1]
		}
	}
	return label, ""
}

// networkScopeSet collects every scope value that identifies a specific
// network in the given config — its network id and its interface name,
// which are the two discriminators the per-network call sites append.
func networkScopeSet(cfg *DesiredConfig) map[string]struct{} {
	out := make(map[string]struct{})
	if cfg == nil {
		return out
	}
	for _, n := range cfg.Networks {
		out[n.NetworkID] = struct{}{}
		if n.Interface.Name != "" {
			out[n.Interface.Name] = struct{}{}
		}
	}
	return out
}

// constellationScopeSet collects the handles the config currently asks the
// host to trust — the discriminator trust_constellation: appends. Handles
// come and go independently of networks, so they need their own reap set;
// without one the map grows by an entry per handle ever advertised, and
// each stale entry is misrouted onto every network as host-global.
func constellationScopeSet(cfg *DesiredConfig) map[string]struct{} {
	out := make(map[string]struct{})
	if cfg == nil {
		return out
	}
	for _, c := range cfg.Constellations {
		out[c.Handle] = struct{}{}
	}
	return out
}

func (m *Manager) fetchDesiredConfig(ctx context.Context) (*DesiredConfig, error) {
	resp, err := m.Client.GetJSON("/api/v1/system/node_api/config/sdwan")
	if err != nil {
		return nil, fmt.Errorf("GET config/sdwan: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("config/sdwan status %d: %s", resp.StatusCode, string(body))
	}

	var envelope struct {
		Success bool          `json:"success"`
		Data    DesiredConfig `json:"data"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return nil, fmt.Errorf("parse config/sdwan: %w", err)
	}
	cfg := envelope.Data
	return &cfg, nil
}

// privateKeyFor — slice 1 ships the private key inline in the config
// response (TopologyCompiler#include_private_key=true on the node-API
// path; the operator topology endpoint never sets it). The agent never
// persists it to disk; it lives only in process memory and in the
// mode-0600 temp file we pass to `wg setconf`.
//
// Slice 2 hardening: split it into a dedicated /node_api/sdwan/keys
// endpoint with a shorter TTL; the inline emit becomes a fallback path.
func (m *Manager) privateKeyFor(net DesiredNetworkConfig) (string, error) {
	if net.Interface.PrivateKey != "" {
		return net.Interface.PrivateKey, nil
	}
	return "", fmt.Errorf("no private key in config response for network %s", net.NetworkID)
}

// Slice 9f — POST observed BGP state for each iBGP-enabled network.
func (m *Manager) postBgpStatusReport(ctx context.Context, observations []*ObservedBgpState) error {
	body, err := json.Marshal(map[string]any{"networks": observations})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		m.Client.PlatformURL+"/api/v1/system/node_api/status/bgp", bodyReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := m.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("status/bgp %d: %s", resp.StatusCode, string(raw))
	}
	return nil
}

func (m *Manager) postStatusReport(ctx context.Context, reports []PeerStatusReport) error {
	body, err := json.Marshal(map[string]any{"peers": reports})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		m.Client.PlatformURL+"/api/v1/system/node_api/status/sdwan", bodyReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := m.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("status/sdwan %d: %s", resp.StatusCode, string(raw))
	}
	return nil
}

// peerReportsFromActual translates wg-show output into the wire-format
// the platform expects. Status classification mirrors Sdwan::Peer's
// HEALTHY_HANDSHAKE_WINDOW (3 minutes) / DEGRADED window (5 minutes).
func peerReportsFromActual(net DesiredNetworkConfig, actual *ActualInterfaceState) []PeerStatusReport {
	pubkeyToPeerID := make(map[string]string, len(net.Peers))
	for _, p := range net.Peers {
		pubkeyToPeerID[p.PublicKey] = p.PeerID
	}

	now := time.Now()
	out := make([]PeerStatusReport, 0, len(actual.Peers))
	for _, ap := range actual.Peers {
		peerID, ok := pubkeyToPeerID[ap.PublicKey]
		if !ok {
			continue // peer is on the wire but not in our desired set; skip
		}
		var handshakeStr string
		status := "disconnected"
		if !ap.LastHandshakeAt.IsZero() {
			handshakeStr = ap.LastHandshakeAt.UTC().Format(time.RFC3339)
			age := now.Sub(ap.LastHandshakeAt)
			switch {
			case age < 3*time.Minute:
				status = "active"
			case age < 5*time.Minute:
				status = "degraded"
			default:
				status = "disconnected"
			}
		}
		out = append(out, PeerStatusReport{
			PeerID:          peerID,
			LastHandshakeAt: handshakeStr,
			RxBytes:         ap.RxBytes,
			TxBytes:         ap.TxBytes,
			Status:          status,
		})
	}
	return out
}

// countHealthyPeers counts the peers this pass observed inside the active
// handshake window. Callers must only record the result for a network they
// actually read — an unread network has no count, not a count of zero.
func countHealthyPeers(reports []PeerStatusReport) int {
	n := 0
	for _, r := range reports {
		if r.Status == "active" {
			n++
		}
	}
	return n
}
