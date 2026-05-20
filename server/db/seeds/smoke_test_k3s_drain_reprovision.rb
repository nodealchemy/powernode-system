# frozen_string_literal: true

# K3s full-lifecycle smoke — Phase 8: Drain + reprovision.
#
# Picks one k3s-agent NodeInstance, marks it stopped (db-tier
# equivalent of drain), destroys the KubernetesNode + NodeInstance,
# then reprovisions a replacement via the standard helper. Validates
# the cascade behavior + node_count restoration.
#
# At site+ tier the drain would use system_drain_instance MCP action,
# wait for pod eviction via kubectl, then system_terminate_instance.
# At db tier we synthesize the equivalent state transitions.
#
# Asserts:
#   - Drained node row status flipped to disconnected
#   - bootstrap_events captured the mark_node_stopped event
#   - After destroy: cluster.node_count decremented to 4
#   - After reprovision + register + ready: cluster.node_count back to 5
#   - Replacement agent has role=agent, status=active
#
# Invoke:
#   cd server && SMOKE_K3S_LEVEL=db bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_drain_reprovision.rb')"

require_relative "_smoke_k3s_helpers"

h = ::System::Seeds::SmokeK3sHelpers
site = ENV.fetch("SMOKE_K3S_SITE", "a").downcase

puts "\n  K3s lifecycle smoke — Phase 8: Drain + reprovision"
puts "  ============================================================"
puts "  Tier:           #{h.current_tier}"

begin
  h.tier_gate(required: "db")
rescue ::System::Seeds::SmokeK3sHelpers::TierInsufficient => e
  h.skipped(e.message)
  exit 0
end

h.preflight!(level: h.current_tier)
account = h.discover_or_create_account!

state = h.state_read
cluster_id = state["site_#{site}_cluster_id"]
agent_instance_ids = Array(state["site_#{site}_agent_instance_ids"])
network_id = state["site_#{site}_network_id"]

h.fail_with("missing state — run phases 1-3 first") unless cluster_id && agent_instance_ids.any?

cluster = ::Devops::KubernetesCluster.find_by(id: cluster_id, account: account)
network = ::Sdwan::Network.find_by(id: network_id, account: account)
h.fail_with("cluster not found") unless cluster
h.fail_with("network not found") unless network

starting_count = cluster.node_count
h.ok("starting state: cluster=#{cluster.name} node_count=#{starting_count}")

# ── Pick one agent to drain ─────────────────────────────────────────
h.step("Pick one k3s-agent to drain + reprovision")
drain_inst_id = agent_instance_ids.first
drain_inst = ::System::NodeInstance.find_by(id: drain_inst_id)
h.fail_with("drain instance #{drain_inst_id[0, 8]} not found") unless drain_inst
h.ok("draining: #{drain_inst.name} (id=#{drain_inst.id[0, 8]})")

drain_kube_node = ::Devops::KubernetesNode.find_by(node_instance_id: drain_inst.id)
h.fail_with("drain kube_node not found") unless drain_kube_node
h.assert(drain_kube_node.role == "agent", "drain target has role=agent")

# ── Drain step (mark_node_stopped at db tier) ───────────────────────
h.step("Drain step: mark_node_stopped")
stopped = ::System::KubernetesClusterProvisionerService.mark_node_stopped!(node_instance: drain_inst)
h.assert(stopped&.status == "disconnected", "node flipped to disconnected (got #{stopped&.status})")

cluster.reload
events = Array(cluster.metadata["bootstrap_events"])
stopped_events = events.select { |e| e["phase"] == "mark_node_stopped" }
h.assert(stopped_events.any?, "bootstrap_events recorded a mark_node_stopped entry")
h.assert(stopped_events.last["message"].to_s.include?(drain_inst.id),
         "stopped event message references the drained instance")

# ── Terminate step (destroy the kube_node + instance) ───────────────
h.step("Terminate step: destroy KubernetesNode + NodeInstance")
drain_kube_node.destroy
cluster.reload

# cluster.node_count auto-decrements via Devops::KubernetesNode#after_destroy
h.assert(cluster.node_count == starting_count - 1,
         "cluster.node_count auto-decremented to #{starting_count - 1} (got #{cluster.node_count})")

# Capture peer + node module assignments before destroying instance so
# we can reproduce them for the replacement
old_node = drain_inst.node
drain_inst.destroy
h.ok("NodeInstance destroyed")

# ── Reprovision step ────────────────────────────────────────────────
h.step("Reprovision step: create replacement agent")
replacement_label = "k3s-#{site}-agent-replacement-#{SecureRandom.hex(2)}"
replacement_inst, replacement_peer = h.bootstrap_node_instance!(
  name: replacement_label, network: network, role: :agent
)
h.ok("replacement: #{replacement_inst.name} (peer=#{replacement_peer.assigned_address})")

# ── Re-join step ────────────────────────────────────────────────────
h.step("Re-join replacement agent into cluster")
::System::KubernetesClusterProvisionerService.register_node_join!(
  node_instance: replacement_inst, role: "agent", k8s_version: "v1.30.5+k3s1"
)
::System::KubernetesClusterProvisionerService.mark_node_ready!(
  node_instance: replacement_inst, k8s_version: "v1.30.5+k3s1"
)

cluster.reload
h.assert(cluster.node_count == starting_count,
         "cluster.node_count restored to #{starting_count} (got #{cluster.node_count})")

replacement_kube_node = ::Devops::KubernetesNode.find_by(node_instance_id: replacement_inst.id)
h.assert(replacement_kube_node.present?, "replacement kube_node exists")
h.assert(replacement_kube_node.role == "agent", "replacement role=agent")
h.assert(replacement_kube_node.status == "active", "replacement status=active")

# ── State sidecar update ────────────────────────────────────────────
new_agent_ids = (agent_instance_ids - [ drain_inst_id ]) + [ replacement_inst.id ]
h.state_write("site_#{site}_agent_instance_ids" => new_agent_ids)

puts "\n  ✅ Phase 8 (drain + reprovision) complete"
puts "  Drained: original agent → disconnected → destroyed"
puts "  Replaced: new agent joined + active; node_count=#{cluster.node_count}"
puts "  K3s lifecycle smoke chain complete (phases 1-8)"
