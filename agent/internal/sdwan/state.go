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
	InstanceID string                  `json:"instance_id"`
	Networks   []DesiredNetworkConfig  `json:"networks"`
	CompiledAt string                  `json:"compiled_at"`
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

// VipConf — one VIP this peer should configure on its loopback so the
// kernel accepts packets destined to the VIP address. Slice 9b emits
// these from Sdwan::TopologyCompiler#vips_held_by; slice 9c will add a
// `routes_via_bgp` flag indicating whether FRR should also announce
// the prefix.
type VipConf struct {
	VipID                string `json:"virtual_ip_id"`
	Name                 string `json:"name"`
	Cidr                 string `json:"cidr"`
	Anycast              bool   `json:"anycast"`
	AdvertisedMed        int    `json:"advertised_med"`
	AdvertisedLocalPref  int    `json:"advertised_local_pref"`
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
