// bridge_applier.go — Phase O1: BridgeApplier strategy interface.
//
// The platform tells the agent which host-side bridges should exist
// (one per logical Sdwan::HostBridge row); the agent makes the kernel
// match. Phase O1 ships LinuxBridgeApplier, the Linux-bridge backend.
// Phase O2 will add an OVSDB-backed implementation alongside;
// per-host network_profile selects which one the Manager constructs.
//
// Why a strategy interface (not a single concrete type): host-side
// bridge management is one of the few SDWAN responsibilities that
// genuinely needs two implementations. Linux-bridge fits Pi-class
// hosts with no daemon overhead; OVS unlocks per-flow telemetry,
// OVN integration, and logical-network ACLs on capable hosts. Both
// implementations share the same DesiredBridge wire format so the
// platform's compiler is profile-agnostic — it emits the desired set
// once, and whichever applier the host runs reconciles it.
//
// Naming convention: every platform-managed bridge name starts with
// `pwnbr-` (short for "powernode bridge"). The full name is
// `pwnbr-<short_id>` where short_id is the first 8 chars of the
// HostBridge UUID. Linux's IFNAMSIZ is 15 chars, leaving 9 chars for
// the short_id portion (pwnbr- = 6 chars). The applier filters
// reads + reaps to this prefix so operator-installed bridges
// (`br0`, `virbr0`, `docker0`, `pwnvbr0` from the manual setup era)
// are left alone.
//
// Apply ordering inside the manager: bridge_applier MUST run BEFORE
// the per-network loop so any bridge a libvirt domain or container
// runtime expects exists at the moment the WG iface or tap iface is
// attached. Mirrors the vrf_applier ordering rule.
//
// Phase O1 of the OVS+OVN dual-profile networking roadmap.

package sdwan

import "context"

// DesiredBridge is the per-bridge intent surfaced from the platform's
// per-host payload. The platform's bridge compiler (Phase O1 server-
// side work) emits one of these per Sdwan::HostBridge row that this
// host owns and that is in compilable state.
type DesiredBridge struct {
	// Name is the kernel-visible bridge interface name. Must be
	// `pwnbr-<short_id>` where short_id is the HostBridge's 8-char
	// derived id, capped at IFNAMSIZ (15 chars total). The applier
	// trusts the platform's allocator to enforce length + uniqueness;
	// it only validates non-empty before calling `ip link`.
	Name string `json:"name"`
	// Kind is the backend implementation hint. "linux" today; "ovs"
	// is reserved for Phase O2. The agent's Manager constructs ONE
	// applier per host based on network_profile, so a heavyweight
	// host running OvsBridgeApplier ignores entries with Kind="linux"
	// (and vice versa). Phase O1 only ships the linux backend, so
	// LinuxBridgeApplier filters on Kind=="" || Kind=="linux".
	Kind string `json:"kind"`
	// Cidrs is the set of IPv4/IPv6 addresses (CIDR form) to install
	// directly on the bridge. Empty is valid — a pure-bridging
	// bridge with no host IP. The applier reconciles: adds missing,
	// removes orphan addresses installed by prior generations of
	// this same DesiredBridge.
	Cidrs []string `json:"cidrs"`
	// MTU is the bridge MTU. 0 means "use kernel default" (1500).
	// Applied unconditionally each tick because the kernel doesn't
	// surface a "did the user mean to set this" bit, and a drift on
	// a bridge MTU breaks every tap iface attached to it.
	MTU int `json:"mtu"`
	// Ipfix is the optional IPFIX exporter config for this bridge.
	// Nil means no IPFIX (LinuxBridgeApplier always ignores; OvsBridgeApplier
	// clears any prior IPFIX on the bridge). Phase O5 — wired by the
	// platform's TopologyCompiler when the host's account has an
	// active Sdwan::IpfixCollector AND this bridge is ovs-kind.
	Ipfix *DesiredIpfix `json:"ipfix,omitempty"`
}

// DesiredIpfix is the per-bridge IPFIX exporter intent. Linux
// bridges ignore this field entirely (no kernel IPFIX hook without
// OVS); only OvsBridgeApplier acts on it.
type DesiredIpfix struct {
	// CollectorID is the platform's Sdwan::IpfixCollector row id;
	// carried for diagnostics + log lines, not consumed by ovs-vsctl.
	CollectorID string `json:"collector_id"`
	// Targets is the list of `host:port` strings ovs-vsctl writes
	// into the IPFIX.targets column. Single-target is the common
	// case in O5; multi-target is supported by OVS and the wire
	// format leaves room for it.
	Targets []string `json:"targets"`
	// Sampling is the OVS IPFIX `sampling` field — emit one record
	// per N packets. 1 means sample every packet; higher values trade
	// fidelity for collector load.
	Sampling int `json:"sampling"`
}

// BridgeApplier abstracts host-side bridge management so the manager
// can be configured per host with the right backend (Linux today,
// OVS in Phase O2) and so tests can run without root or netlink
// access. Implementations MUST be idempotent — calling Apply twice
// with the same desired set on a converged kernel is a no-op.
//
// The interface is intentionally narrow: the platform owns the
// desired-state graph and the applier owns the actual-state diff.
// Per-bridge errors should be recorded by the applier (logging, etc.)
// but Apply should return an error only on conditions that prevent
// the entire reconcile from making progress (e.g. `ip` binary
// missing). The Manager records the error and moves on so the
// SDWAN heartbeat goroutine stays alive.
type BridgeApplier interface {
	Apply(ctx context.Context, desired []DesiredBridge) error
}
