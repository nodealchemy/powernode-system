// Package sdwan implements the agent-side SDWAN reconciler.
//
// On each heartbeat tick the Manager pulls /node_api/config/sdwan,
// diffs the desired per-network interface configs against the kernel's
// actual state (read via `wg show`), applies the differences via shell
// commands, and reports observed state back to /status/sdwan.
//
// The reconciler is *idempotent* — applying the same desired state twice
// is a no-op. Drift detection is delegated to the platform's fleet
// autonomy sensors (slice 5); the agent's job is just to make actual
// match desired.
//
// Slice 1 of the SDWAN plan.
package sdwan

import "time"

// DesiredConfig is the response shape from GET /api/v1/system/node_api/config/sdwan.
// Mirrors the Sdwan::TopologyCompiler#compile_for_peer Ruby return value.
type DesiredConfig struct {
	InstanceID string                 `json:"instance_id"`
	Networks   []DesiredNetworkConfig `json:"networks"`
	CompiledAt string                 `json:"compiled_at"`
	// Phase N0: constellation public keys the host trusts for verifying
	// MC envelopes. Top-level (host-scoped) because trust is shared
	// across every network this host belongs to.
	Constellations []ConstellationTrust `json:"constellations"`
	// Phase N1a: per-host VRF assignments. The vrf_applier consumes this
	// list directly. Top-level because VRFs are host-level kernel state
	// (one VRF per network this host has joined, not per peer).
	VrfAssignments []DesiredVRF `json:"vrf_assignments"`
	// Phase O1: per-host bridge intent. The bridge_applier consumes this
	// list directly. Top-level (host-scoped) because bridges are
	// host-level kernel state owned by the agent's chosen BridgeApplier
	// backend (Linux today; OVS in Phase O2).
	HostBridges []DesiredBridge `json:"host_bridges"`
	// Phase O3: per-host OVN-controller intent. Nil for lightweight
	// hosts or accounts with no active Sdwan::OvnDeployment; populated
	// for heavyweight hosts that need to participate in the OVN logical
	// network. The OvnControllerApplier shells out to systemctl +
	// ovs-vsctl to align local ovn-controller state with this intent.
	OvnControl *DesiredOvnControl `json:"ovn_control"`
}

// ConstellationTrust pairs a constellation handle with its Ed25519
// public key (base64). The agent's MCVerifier uses these to validate
// envelope signatures.
type ConstellationTrust struct {
	Handle       string `json:"handle"`
	PublicKeyB64 string `json:"public_key_b64"`
}

// DesiredNetworkConfig is one network's worth of per-peer config.
type DesiredNetworkConfig struct {
	NetworkID     string         `json:"network_id"`
	NetworkCidr64 string         `json:"network_cidr_64"`
	PeerID        string         `json:"peer_id"`
	Interface     InterfaceConf  `json:"interface"`
	Peers         []PeerConf     `json:"peers"`
	Firewall      *FirewallConf  `json:"firewall"`     // slice 2 — nft ruleset
	Federation    []any          `json:"federation"`   // always [] in v1
	VipsHeld      []VipConf      `json:"vips_held"`    // slice 9b — VIPs to configure on lo
	Bgp           *BgpConf       `json:"bgp"`          // slice 9c — FRR config when routing_protocol=ibgp
	Nat           *NatConf       `json:"nat"`          // slice 7b — DNAT rules when this peer is a hub with port mappings
	// Phase N0: signed membership credential proving this peer's
	// membership in this network. The Manager forwarding gate refuses
	// to keep the WG tunnel up if this is missing or invalid.
	MC            *MCWire        `json:"mc_envelope"`
}

// NatConf is the per-network nat-chain ruleset. The agent's nat_applier
// writes Ruleset to a temp file and applies via `nft -f`. Empty
// Ruleset = no port mappings on this peer; applier removes any
// existing chain.
type NatConf struct {
	Table      string `json:"table"`        // "powernode_sdwan"
	Chain      string `json:"chain"`        // "sdwan_nat_<8-char-net-id>"
	RuleCount  int    `json:"rule_count"`
	Ruleset    string `json:"ruleset"`      // full nft script (may be empty)
	CompiledAt string `json:"compiled_at"`
}

// VipConf — one VIP this peer should configure inside the right VRF
// so the kernel accepts packets destined to the VIP address.
//
// Pre-Phase-N1a, VIPs were installed on the global loopback. Phase N1a
// moves them to per-VRF dummy interfaces (`dummy-sdwan-<handle>`)
// bound to the network's VRF master device. The `VrfName` field is
// stamped by the platform's TopologyCompiler from the holder host's
// Sdwan::HostVrfAssignment row.
type VipConf struct {
	VipID                string `json:"virtual_ip_id"`
	Name                 string `json:"name"`
	Cidr                 string `json:"cidr"`
	Anycast              bool   `json:"anycast"`
	AdvertisedMed        int    `json:"advertised_med"`
	AdvertisedLocalPref  int    `json:"advertised_local_pref"`
	// Phase N1a: kernel VRF master device the dummy iface backing
	// this VIP must be bound to. Empty during the brief window
	// between network creation and HostVrfAssignment activation —
	// vip_applier.go skips entries with an empty VrfName.
	VrfName              string `json:"vrf_name"`
}

// BgpConf — slice 9c: per-network BGP config for this peer when the
// network's routing_protocol == "ibgp". The agent's frr_applier writes
// this to /etc/frr/frr.conf and reloads FRR. Empty/nil = network is in
// static mode; agent should disable FRR for this network.
type BgpConf struct {
	Enabled              bool          `json:"enabled"`
	AsNumber             int64         `json:"as_number"`
	RouterID             string        `json:"router_id"`     // dotted-quad
	IsRouteReflector     bool          `json:"is_route_reflector"`
	RouteReflectorClient bool          `json:"route_reflector_client"`
	Neighbors            []BgpNeighbor `json:"neighbors"`
	Networks             []string      `json:"networks"`        // CIDRs to announce (own /128, lan_subnets, vips)
	HoldTimeSeconds      int           `json:"hold_time_seconds"`
	KeepaliveSeconds     int           `json:"keepalive_seconds"`
	GracefulRestart      bool          `json:"graceful_restart"`
	// FrrText is the platform-rendered frr.conf content. The agent
	// writes this verbatim to /etc/frr/frr.conf. Single source of truth
	// for routing config — the agent is "dumb" (just applies what the
	// platform produces) so that operator-facing UI matches reality.
	FrrText              string        `json:"frr_text"`
}

// BgpNeighbor — one iBGP peering session.
type BgpNeighbor struct {
	NeighborPeerID    string `json:"neighbor_peer_id"`
	NeighborAddress   string `json:"neighbor_address"`   // overlay /128 of remote
	RemoteAs          int64  `json:"remote_as"`           // same as local for iBGP
	RouteReflectorClient bool `json:"route_reflector_client"`
	Description       string `json:"description"`
}

// ObservedBgpState — what frr_observer reports back via the heartbeat
// after polling `vtysh -c "show bgp summary json"`. Slice 9c.
type ObservedBgpState struct {
	NetworkID   string                 `json:"network_id"`
	RouterID    string                 `json:"router_id"`
	LocalAs     int64                  `json:"local_as"`
	Sessions    []ObservedBgpSession   `json:"sessions"`
	LastError   string                 `json:"last_error,omitempty"`
}

// ObservedBgpSession — one BGP neighbor's live state.
type ObservedBgpSession struct {
	NeighborAddress   string `json:"neighbor_address"`
	State             string `json:"state"`             // idle|connect|active|opensent|openconfirm|established
	UptimeSeconds     int    `json:"uptime_seconds"`
	PrefixesReceived  int    `json:"prefixes_received"`
	PrefixesSent      int    `json:"prefixes_sent"`
	LastError         string `json:"last_error,omitempty"`
}

// FirewallConf is the per-network nft ruleset, compiled by the platform's
// Sdwan::FirewallCompiler. The agent writes Ruleset to a temp file and
// applies atomically via `nft -f`. Empty Ruleset = no firewall on this
// network (compiler returned no script — usually a transient state during
// network creation before the chain is initialized).
type FirewallConf struct {
	Table      string `json:"table"`           // "powernode_sdwan"
	Chain      string `json:"chain"`           // "sdwan_<8-char-net-id>"
	Interface  string `json:"interface"`       // "wg-sdwan-<8-char-net-id>"
	Policy     string `json:"policy"`          // "accept" | "drop"
	RuleCount  int    `json:"rule_count"`
	Ruleset    string `json:"ruleset"`         // full nft script
	CompiledAt string `json:"compiled_at"`
}

// InterfaceConf describes the local WireGuard interface for one network.
//
// PrivateKey is inlined on the node-API path only (the platform's
// SdwanController#config sets TopologyCompiler#include_private_key=true
// because the caller's instance-JWT proves they are the owning peer).
// The operator-facing /sdwan/networks/:id/topology endpoint omits it.
// We never persist it to disk — it lives only in process memory and in
// the mode-0600 temp file we hand to `wg setconf`.
type InterfaceConf struct {
	Name          string         `json:"name"`             // wg-sdwan-<8>
	Address       string         `json:"address"`          // /128
	ListenPort    int            `json:"listen_port"`
	MTU           int            `json:"mtu"`
	PrivateKeyRef *PrivateKeyRef `json:"private_key_ref"`  // metadata pointer
	PublicKey     string         `json:"public_key"`       // for log/heartbeat
	PrivateKey    string         `json:"private_key,omitempty"` // node-API only
	// Phase N1a: name of the VRF master device this WG iface must be
	// bound to (`ip link set <iface> master <vrfName>`). The platform
	// derives it from the host's Sdwan::HostVrfAssignment row for the
	// network this iface belongs to. Empty when the network is in
	// static-only routing mode and no VRF has been allocated; in that
	// case wg_applier leaves the iface in the default routing context.
	VrfName       string         `json:"vrf_name,omitempty"`
}

// PrivateKeyRef points at the Sdwan::PeerKey row whose Vault entry holds
// the private half. The agent fetches the actual private key separately
// (this slice fetches inline from the same response — the v2 hardening
// will move it behind a per-tick KeyDistributor pull endpoint).
type PrivateKeyRef struct {
	PeerKeyID string `json:"peer_key_id"`
}

// PeerConf is one [Peer] section in `wg setconf` terms.
type PeerConf struct {
	PeerID              string   `json:"peer_id"`
	PublicKey           string   `json:"public_key"`
	Endpoint            string   `json:"endpoint"` // "host:port" or empty
	AllowedIPs          []string `json:"allowed_ips"`
	PersistentKeepalive *int     `json:"persistent_keepalive"`
}

// ActualInterfaceState is what `wg show` and `ip addr` report for one
// SDWAN-managed interface. Used by the diff to compute the apply plan
// and by the Reporter to push state back to the platform.
type ActualInterfaceState struct {
	Name             string
	Address          string
	ListenPort       int
	PublicKey        string
	Peers            []ActualPeerState
}

// ActualPeerState — kernel-side observation for one peer.
type ActualPeerState struct {
	PublicKey        string
	Endpoint         string
	AllowedIPs       []string
	LastHandshakeAt  time.Time
	RxBytes          int64
	TxBytes          int64
}

// PeerStatusReport is what we POST to /status/sdwan per heartbeat tick.
// The platform's Sdwan::Peer.recompute_status_from_handshake! consumes
// these to roll active|degraded|disconnected.
type PeerStatusReport struct {
	PeerID          string `json:"peer_id"`
	LastHandshakeAt string `json:"last_handshake_at"` // RFC3339, "" if never
	RxBytes         int64  `json:"rx_bytes"`
	TxBytes         int64  `json:"tx_bytes"`
	Status          string `json:"status"` // "active" | "degraded" | "disconnected"
}

// HeartbeatStatus is the SDWAN block that gets nested into the main
// HeartbeatPayload. One entry per WG interface present on the node.
type HeartbeatStatus struct {
	Interface       string `json:"interface"`
	NetworkID       string `json:"network_id"`
	PeerCount       int    `json:"peer_count"`
	HealthyPeers    int    `json:"healthy_peers"`
	LastReconcileAt string `json:"last_reconcile_at"`
	LastError       string `json:"last_error,omitempty"`
}
