# frozen_string_literal: true

# System extension — Phase 2 K3s runtime smoke test.
#
# Platform-side smoke. Validates the full K3s backend stack against
# the dev database — service layer, MCP tools, controller phases —
# without needing real k3s install.
#
# Coverage:
#
#   1. Bootstrap a fresh cluster via KubernetesClusterProvisionerService
#      with a fake kubeconfig + tokens. Verify cluster row + bootstrap
#      KubernetesNode (role=server) created.
#   2. Idempotent re-bootstrap: same call refreshes credentials, doesn't
#      duplicate.
#   3. join_request from an agent NodeInstance returns the cluster's
#      api_endpoint + agent_token.
#   4. register_node_join + mark_node_ready promote the worker to
#      active; promote cluster to 'active' once the bootstrap server
#      reports ready.
#   5. mark_node_stopped flips a node to disconnected.
#   6. MCP kubernetes_list_clusters / get_cluster / list_nodes return
#      the right data.
#   7. MCP kubernetes_get_kubeconfig returns the YAML + api_endpoint.
#   8. MCP kubernetes_decommission_cluster destroys cluster + cascades
#      to nodes.
#   9. Negative: bootstrap rejected when NodeInstance has no SDWAN peer.
#  10. Negative: join_request rejected when no cluster exists.
#
# Out of scope (next session, requires QEMU + composefs blob build):
#   - Real k3s server install + bootstrap
#   - Agent-driven phase=bootstrap roundtrip via runtime/handshake
#   - Pod sync (deferred to slice 5 worker job)
#   - End-to-end kubectl roundtrip via SDWAN overlay
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_runtime.rb')"

require "json"

step = ->(label) { puts "\n  [step] #{label}" }
ok   = ->(msg) { puts "    ✓ #{msg}" }
fail_with = ->(msg) {
  puts "    ✗ #{msg}"
  abort("  💥 SMOKE FAIL")
}
assert = ->(condition, msg) { condition ? ok.call(msg) : fail_with.call(msg) }

puts "\n  Phase 2 K3s runtime smoke test"
puts "  ================================"
puts "  Today: #{Date.today}, Rails env: #{Rails.env}"

# ── Find a NodeInstance with SDWAN peer ─────────────────────────────
step.call("Discover a NodeInstance with at least one SDWAN peer")

server_instance = ::System::NodeInstance.joins(
  "INNER JOIN sdwan_peers ON sdwan_peers.node_instance_id = system_node_instances.id"
).where.not("sdwan_peers.assigned_address IS NULL").first

fail_with.call("No NodeInstance with SDWAN peer found") unless server_instance

account = server_instance.account
node = server_instance.node
peer = ::Sdwan::Peer.where(node_instance_id: server_instance.id)
                    .where.not(assigned_address: nil)
                    .order(:created_at)
                    .first

ok.call("server instance=#{server_instance.name} (id=#{server_instance.id[0, 8]})")
ok.call("account=#{account.name} (id=#{account.id[0, 8]})")
ok.call("server overlay=#{peer.assigned_address}")

# ── Setup module assignments (k3s-server + k3s-agent) ──────────────
step.call("Ensure k3s-server module is seeded + assigned")

k3s_server_mod = ::System::NodeModule.where(account: account, name: "k3s-server").first
fail_with.call("k3s-server not seeded — run k3s_modules.rb") unless k3s_server_mod

server_assign = ::System::NodeModuleAssignment.where(node: node, node_module: k3s_server_mod).first
created_server_assign = false
unless server_assign
  server_assign = ::System::NodeModuleAssignment.create!(
    node: node, node_module: k3s_server_mod, enabled: true
  )
  created_server_assign = true
end
ok.call("server module assignment #{created_server_assign ? 'created' : 'present'}")

# ── Cleanup any prior test residue ─────────────────────────────────
step.call("Clean any leftover Devops::KubernetesCluster from a previous smoke run")
prior = ::Devops::KubernetesCluster.where(account_id: account.id)
prior_count = prior.count
prior.destroy_all
ok.call("deleted #{prior_count} prior cluster(s)")

# ────────────────────────────────────────────────────────────────────
# Smoke 1: Bootstrap
# ────────────────────────────────────────────────────────────────────

step.call("Bootstrap a K3s cluster via KubernetesClusterProvisionerService")

cluster = ::System::KubernetesClusterProvisionerService.bootstrap!(
  node_instance: server_instance,
  kubeconfig: <<~YAML.strip,
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        server: https://[#{peer.assigned_address.split('/').first}]:6443
      name: smoke-test
    contexts: []
    users: []
  YAML
  server_token: "K10smoke-server-token-#{SecureRandom.hex(8)}",
  agent_token: "K10smoke-agent-token-#{SecureRandom.hex(8)}",
  k8s_version: "v1.30.4+k3s1"
)

assert.call(cluster.persisted?, "cluster row created")
assert.call(cluster.flavor == "k3s", "flavor=k3s")
assert.call(cluster.status == "bootstrapping", "initial status=bootstrapping")
assert.call(cluster.k8s_version == "v1.30.4+k3s1", "k8s_version recorded")
assert.call(cluster.api_endpoint.start_with?("https://["), "api_endpoint is bracketed IPv6")
assert.call(cluster.api_endpoint.end_with?(":6443"), "api_endpoint port=6443")
assert.call(cluster.node_count == 1, "node_count=1 after bootstrap")
assert.call(cluster.encrypted_kubeconfig.include?("apiVersion: v1"), "kubeconfig stored")
assert.call(cluster.encrypted_server_token.start_with?("K10"), "server_token stored")

bootstrap_node = cluster.kubernetes_nodes.first
assert.call(bootstrap_node.role == "server", "bootstrap node role=server")
assert.call(bootstrap_node.status == "active", "bootstrap node status=active")
assert.call(bootstrap_node.node_instance_id == server_instance.id, "node bound to server instance")

# ────────────────────────────────────────────────────────────────────
# Smoke 2: Idempotency
# ────────────────────────────────────────────────────────────────────

step.call("Idempotency — re-bootstrap refreshes credentials, doesn't duplicate")

cluster2 = ::System::KubernetesClusterProvisionerService.bootstrap!(
  node_instance: server_instance,
  kubeconfig: "rotated-kubeconfig-yaml",
  server_token: "K10rotated-server",
  agent_token: "K10rotated-agent",
  k8s_version: "v1.30.5+k3s1"
)

assert.call(cluster2.id == cluster.id, "same cluster_id returned")
cluster.reload
assert.call(cluster.encrypted_kubeconfig == "rotated-kubeconfig-yaml", "kubeconfig refreshed")
assert.call(cluster.k8s_version == "v1.30.5+k3s1", "k8s_version refreshed")
assert.call(::Devops::KubernetesCluster.where(account_id: account.id).count == 1,
            "still exactly 1 cluster")

# ────────────────────────────────────────────────────────────────────
# Smoke 3: Join request
# ────────────────────────────────────────────────────────────────────

step.call("join_request returns api_endpoint + agent_token")

# Create a separate worker NodeInstance in the same account.
worker_instance = ::System::NodeInstance.create!(
  node: node, name: "smoke-k3s-worker-#{SecureRandom.hex(3)}",
  variety: "physical", status: "pending"
)

# Worker also needs an SDWAN peer for ID purposes (not used in
# join_request itself — that's a server-only concern).
join_payload = ::System::KubernetesClusterProvisionerService.join_request!(
  node_instance: worker_instance
)
assert.call(join_payload[:cluster_id] == cluster.id, "cluster_id resolves to active cluster")
assert.call(join_payload[:api_endpoint] == cluster.api_endpoint, "api_endpoint mirrors cluster")
assert.call(join_payload[:agent_token] == "K10rotated-agent", "agent_token returned")

# ────────────────────────────────────────────────────────────────────
# Smoke 4: register_node_join + mark_node_ready
# ────────────────────────────────────────────────────────────────────

step.call("Register worker join + mark ready")

worker_node = ::System::KubernetesClusterProvisionerService.register_node_join!(
  node_instance: worker_instance,
  role: "agent",
  k8s_version: "v1.30.5+k3s1"
)
assert.call(worker_node.persisted?, "worker KubernetesNode created")
assert.call(worker_node.role == "agent", "worker role=agent")
assert.call(worker_node.status == "joining", "worker initial status=joining")

cluster.reload
assert.call(cluster.node_count == 2, "node_count incremented to 2")

ready_node = ::System::KubernetesClusterProvisionerService.mark_node_ready!(
  node_instance: worker_instance,
  k8s_version: "v1.30.5+k3s1"
)
assert.call(ready_node.status == "active", "worker promoted to active")
assert.call(ready_node.last_heartbeat_at > 5.seconds.ago, "last_heartbeat_at stamped")

# Bootstrap server reports ready → cluster goes from bootstrapping → active
::System::KubernetesClusterProvisionerService.mark_node_ready!(
  node_instance: server_instance,
  k8s_version: "v1.30.5+k3s1"
)
cluster.reload
assert.call(cluster.status == "active", "cluster promoted bootstrapping → active")

# ────────────────────────────────────────────────────────────────────
# Smoke 5: MCP read tools
# ────────────────────────────────────────────────────────────────────

step.call("MCP kubernetes_list_clusters")

admin = account.users.first
fail_with.call("no admin user on account") unless admin

cluster_tool = ::Ai::Tools::KubernetesClusterTool.new(account: account, agent: nil, user: admin)

list_result = cluster_tool.send(:call, action: "kubernetes_list_clusters")
assert.call(list_result[:success], "list returned success")
assert.call(list_result[:count] >= 1, "at least 1 cluster")
ids = list_result[:clusters].map { |c| c[:id] }
assert.call(ids.include?(cluster.id), "our cluster is in the list")

step.call("MCP kubernetes_get_cluster")

get_result = cluster_tool.send(:call, action: "kubernetes_get_cluster", cluster_id: cluster.id)
assert.call(get_result[:success], "get returned success")
assert.call(get_result[:cluster][:id] == cluster.id, "cluster details matches")
assert.call(get_result[:cluster][:flavor] == "k3s", "flavor in details")
assert.call(get_result[:cluster][:node_count] == 2, "node_count in details")

step.call("MCP kubernetes_list_nodes")

nodes_result = cluster_tool.send(:call, action: "kubernetes_list_nodes", cluster_id: cluster.id)
assert.call(nodes_result[:success], "list_nodes returned success")
assert.call(nodes_result[:count] == 2, "2 nodes in response")
roles = nodes_result[:nodes].map { |n| n[:role] }
assert.call(roles.sort == %w[agent server], "expected roles: agent + server")

# ────────────────────────────────────────────────────────────────────
# Smoke 6: MCP kubeconfig retrieval
# ────────────────────────────────────────────────────────────────────

step.call("MCP kubernetes_get_kubeconfig")

prov_tool = ::Ai::Tools::KubernetesProvisioningTool.new(account: account, agent: nil, user: admin)
kc_result = prov_tool.send(:call, action: "kubernetes_get_kubeconfig", cluster_id: cluster.id)
assert.call(kc_result[:success], "kubeconfig retrieval succeeds")
assert.call(kc_result[:kubeconfig] == "rotated-kubeconfig-yaml", "kubeconfig content matches")
assert.call(kc_result[:api_endpoint] == cluster.api_endpoint, "api_endpoint included")

# ────────────────────────────────────────────────────────────────────
# Smoke 7: mark_node_stopped
# ────────────────────────────────────────────────────────────────────

step.call("Mark worker stopped")

stopped = ::System::KubernetesClusterProvisionerService.mark_node_stopped!(
  node_instance: worker_instance
)
assert.call(stopped.status == "disconnected", "worker flipped to disconnected")

# ────────────────────────────────────────────────────────────────────
# Smoke 8: MCP decommission
# ────────────────────────────────────────────────────────────────────

step.call("MCP kubernetes_decommission_cluster")

decom_result = prov_tool.send(:call, action: "kubernetes_decommission_cluster", cluster_id: cluster.id)
assert.call(decom_result[:success], "decommission returned success")
assert.call(decom_result[:freed_node_count] == 2, "2 nodes freed")
assert.call(::Devops::KubernetesCluster.where(id: cluster.id).none?, "cluster row destroyed")
assert.call(::Devops::KubernetesNode.where(kubernetes_cluster_id: cluster.id).none?,
            "all member node rows cascaded")

# ────────────────────────────────────────────────────────────────────
# Smoke 9: Negative — bootstrap without SDWAN peer
# ────────────────────────────────────────────────────────────────────

step.call("Negative: bootstrap rejected when NodeInstance has no SDWAN peer")

orphan = ::System::NodeInstance.create!(
  node: node, name: "smoke-k3s-orphan-#{SecureRandom.hex(3)}",
  variety: "physical", status: "pending"
)
begin
  ::System::KubernetesClusterProvisionerService.bootstrap!(
    node_instance: orphan, kubeconfig: "x", server_token: "y",
    agent_token: "z", k8s_version: "v1"
  )
  fail_with.call("expected MissingSdwanPeerError")
rescue ::System::KubernetesClusterProvisionerService::MissingSdwanPeerError => e
  assert.call(e.message.include?("SDWAN"), "error mentions SDWAN: #{e.message[0, 80]}")
end
orphan.destroy

# ────────────────────────────────────────────────────────────────────
# Smoke 10: Negative — join_request without cluster
# ────────────────────────────────────────────────────────────────────

step.call("Negative: join_request rejected when no cluster exists")

# After decommission above, there are no clusters in the account.
begin
  ::System::KubernetesClusterProvisionerService.join_request!(
    node_instance: worker_instance
  )
  fail_with.call("expected NoClusterAvailableError")
rescue ::System::KubernetesClusterProvisionerService::NoClusterAvailableError => e
  assert.call(e.message.include?("no Kubernetes cluster"), "error mentions missing cluster")
end

# ────────────────────────────────────────────────────────────────────
# Cleanup
# ────────────────────────────────────────────────────────────────────

step.call("Cleanup")

worker_instance.destroy
ok.call("worker NodeInstance destroyed")

if created_server_assign
  server_assign.destroy
  ok.call("removed test-created server module assignment")
else
  ok.call("server module assignment retained (existed before smoke)")
end

puts "\n  ✅ ALL PHASE 2 K3S BACKEND SMOKE CHECKS PASSED"
puts "  ============================================="
puts "  Validated:"
puts "    - Bootstrap creates Devops::KubernetesCluster + bootstrap KubernetesNode"
puts "    - Idempotent re-bootstrap refreshes credentials"
puts "    - join_request returns api_endpoint + agent_token"
puts "    - register_node_join increments cluster.node_count"
puts "    - mark_node_ready promotes worker; bootstrap server promotion → cluster active"
puts "    - mark_node_stopped flips disconnected"
puts "    - MCP kubernetes_list_clusters / get_cluster / list_nodes"
puts "    - MCP kubernetes_get_kubeconfig returns YAML"
puts "    - MCP kubernetes_decommission_cluster cascade-deletes nodes"
puts "    - SDWAN-less bootstrap rejected"
puts "    - join_request without cluster rejected"
puts ""
puts "  NOT validated by this smoke (requires QEMU + composefs blob build):"
puts "    - Real k3s install + bootstrap on a NodeInstance"
puts "    - Agent-driven phase=bootstrap via runtime/handshake HTTP"
puts "    - Pod sync (deferred to slice 5 worker job)"
puts "    - kubectl over the SDWAN overlay"
