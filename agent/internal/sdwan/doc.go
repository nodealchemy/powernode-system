// Package sdwan implements the agent-side SDWAN reconciler: WireGuard peers,
// VRFs, host bridges, nftables firewall + NAT, virtual IPs, and FRR (iBGP)
// configuration.
//
// The platform owns the DESIRED state; this package observes the ACTUAL state
// and makes actual match desired. Each heartbeat tick, Manager.Tick:
//
//  1. GET  /api/v1/system/node_api/config/sdwan   → DesiredConfig
//  2. Reads the kernel's actual state (`wg show`, FrrObserver over
//     `vtysh -c "show running-config"`) into ActualInterfaceState /
//     ActualPeerState
//  3. Applies the differences through the applier seams below
//  4. POST /api/v1/system/node_api/status/sdwan   ← observed state
//
// Reconciliation is IDEMPOTENT — applying the same desired state twice is a
// no-op. Drift detection belongs to the platform's fleet autonomy sensors; the
// agent only converges.
//
// # Key types
//
//	Manager               — the reconcile orchestrator, called from the
//	                        runtime tick; holds one applier per subsystem
//	DesiredConfig         — the platform's compiled intent, mirroring
//	                        Sdwan::TopologyCompiler#compile_for_peer;
//	                        DesiredNetworkConfig per overlay network, plus
//	                        DesiredVRF / DesiredBridge / DesiredVip /
//	                        DesiredIpfix / DesiredOvnControl
//	ActualInterfaceState  — what `wg show` reports for one interface
//	ActualPeerState       — what it reports for one peer
//	BgpConf / BgpNeighbor — the FRR side of the desired state
//
// There is no Config, Snapshot or Diff type: desired state is DesiredConfig,
// observed state is the Actual* structs, and the difference is computed inside
// each applier rather than materialised as a diff object.
//
// # Applier seams
//
// Every subsystem is an interface so tests can assert command shape without
// root: WgApplier, NftablesApplier, NatApplier, VipApplier, VRFApplier,
// BridgeApplier, FrrApplier and FrrObserver. Their shell implementations live
// in the correspondingly named *_applier.go files.
//
// Server-side counterpart: extensions/system/server/app/services/sdwan/* and
// app/controllers/api/v1/system/node_api/sdwan_controller.rb.
package sdwan
