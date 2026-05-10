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
	// Phase N0: per-(peer, network) MC cache + Ed25519 trust store.
	// The forwarding gate refuses to bring up tunnels without a valid
	// cached MC.
	MCVerifier *MCVerifier
	OnError    func(string, error)

	mu              sync.Mutex
	lastReconcileAt time.Time
	lastError       error
	lastDesired     *DesiredConfig
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
		MCVerifier:      NewMCVerifier(),
		OnError:         onError,
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

	// Phase N0: trust every constellation pubkey the controller advertises.
	// Idempotent; re-trusting an existing handle is a no-op.
	if m.MCVerifier != nil {
		for _, c := range desired.Constellations {
			if err := m.MCVerifier.TrustConstellation(c.Handle, c.PublicKeyB64); err != nil {
				m.recordError("trust_constellation:"+c.Handle, err)
			}
		}
	}

	// Phase N1a: ensure all per-host VRF master devices exist BEFORE the
	// per-network loop runs — wg_applier needs the VRF to bind interfaces
	// to. Errors are recorded but don't abort the loop; per-network
	// applies will fail individually if their VRF is missing.
	if m.VRFApplier != nil {
		if err := m.VRFApplier.Apply(ctx, desired.VrfAssignments); err != nil {
			m.recordError("apply_vrfs", err)
		}
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
		if err := applier.Apply(ctx, desired.HostBridges); err != nil {
			m.recordError(fmt.Sprintf("apply_bridges[%d]", i), err)
		}
	}

	// Build the desired-interface set so we can identify orphans below.
	desiredNames := make(map[string]struct{}, len(desired.Networks))
	for _, n := range desired.Networks {
		desiredNames[n.Interface.Name] = struct{}{}
	}

	// Apply each desired network. We continue on per-network error so a
	// single bad network doesn't block the others.
	var reports []PeerStatusReport
	for _, net := range desired.Networks {
		// Phase N0 forwarding gate: no MC, or invalid MC, means we tear
		// down any existing interface and skip apply for this tick. The
		// next config push from the controller will carry a fresh MC.
		if m.MCVerifier != nil {
			if net.MC == nil {
				m.recordError("mc_missing:"+net.NetworkID, fmt.Errorf("no MC envelope in config push for peer %s", net.PeerID))
				_ = m.Applier.RemoveInterface(ctx, net.Interface.Name)
				m.MCVerifier.Forget(net.PeerID, net.NetworkID)
				continue
			}
			if _, err := m.MCVerifier.Validate(net.PeerID, net.NetworkID, net.MC, time.Now()); err != nil {
				m.recordError("mc_validate:"+net.NetworkID, err)
				_ = m.Applier.RemoveInterface(ctx, net.Interface.Name)
				continue
			}
		}

		privateKey, err := m.privateKeyFor(net)
		if err != nil {
			m.recordError("private_key_lookup", err)
			continue
		}

		if err := m.Applier.ApplyInterface(ctx, net.Interface, net.Peers, privateKey); err != nil {
			m.recordError("apply_interface:"+net.Interface.Name, err)
			continue
		}

		// Apply the firewall ruleset AFTER the wg interface is up — the
		// nft script references the interface by name (`iif "wg-sdwan-..."`),
		// so attempting to install rules before the interface exists works
		// (nft tolerates non-existent iif names) but the rules wouldn't
		// match anything until the interface comes up. Order this way so
		// each tick converges to a known-good state on the first apply.
		if net.Firewall != nil && m.NftablesApplier != nil {
			if err := m.NftablesApplier.ApplyRuleset(ctx, net.NetworkID, net.Firewall); err != nil {
				m.recordError("apply_firewall:"+net.NetworkID, err)
				// Don't `continue` — even if firewall failed, the wg state
				// reporting below is still meaningful for operator triage.
			}
		}

		// Slice 7b — apply NAT chain (DNAT for hub-published services).
		// Empty NatConf.Ruleset is the signal to tear down the chain;
		// the applier handles that path internally.
		if net.Nat != nil && m.NatApplier != nil {
			if err := m.NatApplier.ApplyRuleset(ctx, net.NetworkID, net.Nat); err != nil {
				m.recordError("apply_nat:"+net.NetworkID, err)
			}
		}

		actual, err := m.Applier.ReadActualState(ctx, net.Interface.Name)
		if err != nil {
			m.recordError("read_actual:"+net.Interface.Name, err)
			continue
		}

		reports = append(reports, peerReportsFromActual(net, actual)...)
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
		if err := m.VipApplier.ApplyVips(ctx, allVips); err != nil {
			m.recordError("apply_vips", err)
		}
	}

	// Slice 9c — FRR is a single host-wide daemon. We use the first
	// iBGP-enabled network's BgpConf (works for the single-iBGP-network
	// case which is the slice 9c MVP). Multi-network aggregation will
	// merge neighbors + announcements across networks in a follow-up.
	var iBgpNetworkIDs []string
	if m.FrrApplier != nil {
		var firstEnabled *BgpConf
		for _, net := range desired.Networks {
			if net.Bgp != nil && net.Bgp.Enabled {
				if firstEnabled == nil {
					firstEnabled = net.Bgp
				}
				iBgpNetworkIDs = append(iBgpNetworkIDs, net.NetworkID)
			}
		}
		if firstEnabled != nil {
			if err := m.FrrApplier.ApplyConfig(ctx, firstEnabled); err != nil {
				m.recordError("apply_frr", err)
			}
		} else {
			// No iBGP networks — disable FRR (idempotent; tolerates
			// "frr already stopped").
			if err := m.FrrApplier.DisableFrr(ctx); err != nil {
				m.recordError("disable_frr", err)
			}
		}
	}

	// Slice 9f — observe FRR's actual session state and report to the
	// platform. Polls vtysh once and posts the result; the platform
	// upserts Sdwan::BgpSession rows so the routing dashboard reflects
	// reality, not just the desired config we shipped.
	if m.FrrObserver != nil && len(iBgpNetworkIDs) > 0 {
		obsCtx, cancel := ObservationContext(ctx)
		defer cancel()
		var observations []*ObservedBgpState
		for _, nid := range iBgpNetworkIDs {
			obs, err := m.FrrObserver.ObserveBgp(obsCtx, nid)
			if err != nil {
				m.recordError("observe_bgp:"+nid, err)
				continue
			}
			observations = append(observations, obs)
		}
		if len(observations) > 0 {
			if err := m.postBgpStatusReport(ctx, observations); err != nil {
				m.recordError("post_bgp_status", err)
			}
		}
	}

	if len(reports) > 0 {
		if err := m.postStatusReport(ctx, reports); err != nil {
			m.recordError("post_status", err)
		}
	}

	m.mu.Lock()
	m.lastReconcileAt = time.Now()
	m.lastError = nil
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
	out := make([]HeartbeatStatus, 0, len(m.lastDesired.Networks))
	for _, net := range m.lastDesired.Networks {
		out = append(out, HeartbeatStatus{
			Interface:       net.Interface.Name,
			NetworkID:       net.NetworkID,
			PeerCount:       len(net.Peers),
			LastReconcileAt: m.lastReconcileAt.UTC().Format(time.RFC3339),
			LastError:       errString(m.lastError),
		})
	}
	return out
}

// ------------------------------------------------------------------
// Internals
// ------------------------------------------------------------------

func (m *Manager) recordError(label string, err error) {
	m.OnError(label, err)
	m.mu.Lock()
	m.lastError = err
	m.mu.Unlock()
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
	if m.Client.InstanceToken != "" {
		req.Header.Set("Authorization", "Bearer "+m.Client.InstanceToken)
	}
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
	if m.Client.InstanceToken != "" {
		req.Header.Set("Authorization", "Bearer "+m.Client.InstanceToken)
	}
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

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
