// Package sdwan applies SDWAN configuration on a NodeInstance: WireGuard
// peers, nftables rules, NAT, FRR (iBGP) configuration.
//
// The platform owns the *desired* SDWAN state; this package observes the
// *actual* state and reconciles. Each tick:
//
//   1. Fetch desired config from /api/v1/system/node_api/sdwan
//   2. Diff against current wg + nft + FRR state (FrrObserver)
//   3. Apply deltas via wg-quick (peer config), nft (firewall rules),
//      iptables-translate (NAT for legacy port mappings), and vtysh (FRR config)
//   4. Post results back to the platform
//
// # Sub-modules
//
//   - manager.go          orchestrates the reconcile loop
//   - frr_applier.go      builds frr.conf from platform desired state
//   - frr_observer.go     parses `vtysh -c "show running-config"` for diff
//   - nftables_applier.go builds nft ruleset from FirewallRule rows
//   - nat_applier.go      port mapping nft rules
//
// # Slice support
//
//   - Slice 3 — first-class VIPs (holder negotiation client-side)
//   - Slice 9 a-f — static subnet routing, iBGP, route policies (FRR config
//                   compilation done platform-side; agent applies the
//                   precomputed frr.conf)
//   - Slice 10 — daemon.json overrides for dockerd peer addresses
//   - Slice 11 — federation peer support (in active sweep; stubs present)
//
// # Key types
//
//   Manager     — top-level reconcile orchestrator; called from runtime.Tick
//   Config      — desired state from platform: peers + rules + routes
//   Snapshot    — observed state: current wg + nft + FRR
//   Diff        — { peers_to_add, peers_to_remove, rules_to_apply, ... }
//
// Server-side counterpart: extensions/system/server/app/services/sdwan/* +
// app/controllers/api/v1/system/node_api/sdwan_controller.rb.
package sdwan
