// Package k3sd reconciles K3s server + agent state on a NodeInstance.
//
// Ships the Phase 2 container runtime path:
//
//   - When `k3s-server` module is assigned: install k3s, run as control plane,
//     post phase=bootstrap to the platform; capture the kubeconfig + agent
//     token from /etc/rancher/k3s/ and post in subsequent reconcile.
//
//   - When `k3s-agent` module is assigned: post phase=join_request
//     (with target_cluster_id when the operator configured one — see
//     Multi-cluster below), receive {api_endpoint, agent_token}, write
//     systemd drop-in at
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
//	ServerManager       — state machine for the k3s-server role
//	AgentManager        — state machine for the k3s-agent role
//	ServerApplier /     — the shellout seams, one per role; the production
//	AgentApplier          implementations are ShellServerApplier and
//	                      ShellAgentApplier (apt + systemctl + curl)
//	Client              — typed client for the handshake endpoint; the wire
//	                      types are HandshakeRequest, JoinRequestPayload,
//	                      BootstrapAck, ReadyAck, StoppedAck and
//	                      HandshakeError, with Phase naming the phase constant
//	BootstrapConfig     — CNI knobs only, fetched via BootstrapConfigAPI
//	                      (HTTPBootstrapConfigClient); it carries NO server URL
//	                      or join token
//	AgentJoinConfig     — what the agent applier writes into the systemd
//	                      drop-in after a successful join_request
//	BootstrapState      — persisted across restarts (persistence.go)
//
// applier.go and shell_applier.go are in THIS package, not a sibling: the
// install + config + systemd work never moved out.
//
// Multi-cluster (use case 3 in USE_CASE_MATRIX.md): JoinRequest carries a
// target_cluster_id discriminator, and the platform validates that the target
// cluster belongs to the same account and isn't in error state. WIRED end to
// end (IMP-a5f236e8cc56) — AgentManager.TargetClusterID is refreshed each
// tick, before Reconcile, from k3sd.HTTPAgentConfigClient, a dedicated
// channel separate from ModulesAPI (applier.go), which still hands the
// reconcilers module names only. The value comes from the calling node's
// enabled k3s-agent NodeModuleAssignment#config["target_cluster_id"], and the
// platform surfaces it only when it names a live in-account, non-error
// cluster — otherwise it's empty, same as an unconfigured assignment. An
// account with more than one non-error cluster and an empty/unresolvable
// target still has its worker joins refused (AmbiguousClusterError -> 409,
// system.k3s_ambiguous_cluster_join_refused at severity high) rather than
// mis-routed — it never guesses. An account with exactly one non-error
// cluster resolves without a target; an account with none fails 422 instead.
// Changing target_cluster_id after a join does not relocate the worker —
// only a fresh join consults it.
//
// The api_endpoint returned to k3s-agent is an Sdwan::VirtualIp /128, which
// keeps kubectl + worker K3S_URL pointed at a stable address across a server
// RESTART. It is not HA: there is no promotion target. allocate_api_vip!
// seeds failover_holder_peer_ids empty and no second k3s-server ever joins an
// existing cluster (InstallK3sServer runs a bare INSTALL_K3S_EXEC=server with
// no --server/--token/--cluster-init; WriteJoinConfig exists on the agent
// applier only; ServerManager never calls JoinRequest). A second k3s-server
// NodeInstance bootstraps a SEPARATE cluster, which then refuses every later
// worker join. Losing the bootstrap server is an outage until it is restored.
// K3s HA is PARKED, not queued. See docs/USE_CASE_MATRIX.md, Use Case 2.
//
// # Handshake phases
//
// Shared with the docker daemon flow (POST
// /api/v1/system/node_api/runtime/handshake) but with K3s-specific phases:
//
//	bootstrap     (k3s-server only) — a fresh K3s cluster came up. Body
//	              carries the captured kubeconfig + server/agent join tokens.
//	              Platform creates a Devops::KubernetesCluster row.
//
//	join_request  (k3s-agent only) — asks the platform for the cluster's
//	              api_endpoint + agent_token. See Multi-cluster above for why
//	              target_cluster_id is always empty on this phase.
//
//	ready         (both) — the kubelet is up; platform flips the
//	              KubernetesNode to status=active. The agent DOES send its
//	              cached ClusterID here, forwarded as target_cluster_id, so
//	              membership resolves on every ready re-fire.
//
//	stopped       (both) — clean shutdown; platform flips the node to
//	              status=disconnected.
//
// Server-side counterpart: extensions/system/server/app/services/system/
// kubernetes_cluster_provisioner_service.rb.
package k3sd
