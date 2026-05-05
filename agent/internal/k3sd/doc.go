// Package k3sd reconciles K3s server + agent state on a NodeInstance.
//
// Ships the Phase 2 container runtime path:
//
//   - When `k3s-server` module is assigned: install k3s, run as control plane,
//     post phase=bootstrap to the platform; capture the kubeconfig + agent
//     token from /etc/rancher/k3s/ and post in subsequent reconcile.
//
//   - When `k3s-agent` module is assigned: post phase=join_request with
//     metadata.target_cluster_id (multi-cluster discriminator), receive
//     {api_endpoint, agent_token}, write systemd drop-in at
//     /etc/systemd/system/k3s-agent.service.d/override.conf, start k3s-agent.service.
//
// # State machine (server)
//
//	detected → installing → bootstrapping → ready
//	                                ↓
//	                       capturing kubeconfig
//
// # State machine (agent)
//
//	detected → installing → join_request → join_pending → ready
//
// # Key types
//
//   ServerManager     — state machine for k3s-server role
//   AgentManager      — state machine for k3s-agent role
//   Applier           — interface for shellout side effects
//   ShellApplier      — production impl; uses apt + systemctl + curl
//   Handshake         — client for /api/v1/system/node_api/runtime/handshake
//
// Multi-cluster (use case 3 in USE_CASE_MATRIX.md): the agent reads
// metadata.target_cluster_id from the module assignment at boot and passes
// it through to JoinRequest. The platform validates the target cluster
// belongs to the same account and isn't in error state.
//
// Slice 3 VIP failover: the api_endpoint returned to k3s-agent is an
// Sdwan::VirtualIp /128, so kubectl + worker K3S_URL survive control-plane
// node failures via VIP holder promotion.
//
// Server-side counterpart: extensions/system/server/app/services/system/
// kubernetes_cluster_provisioner_service.rb.
package k3sd
