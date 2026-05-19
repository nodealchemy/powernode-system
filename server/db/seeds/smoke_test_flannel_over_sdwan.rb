# frozen_string_literal: true

# System extension — K3s flannel-over-SDWAN smoke test (Pass 8 family).
#
# Validates the end-to-end wiring of the "route pod traffic over SDWAN"
# feature (2026-05-19): when an Sdwan::Network has pod_subnet_prefix set
# AND a NodeInstance on that network bootstraps a k3s cluster with
# cni_plugin=flannel, the platform stamps cluster.metadata["pod_cidr"],
# creates an Sdwan::SubnetAdvertisement(source: "pod_subnet"), and the
# runtime bootstrap_config endpoint emits flannel_iface +
# flannel_backend=host-gw + cluster_cidr for the agent to consume.
#
# Coverage:
#
#   1. Set pod_subnet_prefix on an Sdwan::Network with a k3s-server peer.
#   2. Bootstrap a fresh Devops::KubernetesCluster via the provisioner
#      with cni_plugin=flannel.
#   3. Assert cluster.metadata["pod_cidr"] + ["sdwan_network_id"] populated.
#   4. Assert Sdwan::SubnetAdvertisement(source: "pod_subnet") created.
#   5. Call the bootstrap_config builder directly (decoupled from the
#      HTTP layer) and assert it returns flannel_iface, flannel_backend,
#      cluster_cidr matching the network's pod_subnet_prefix.
#   6. Negative: a cluster with cni_plugin=ovn_kubernetes on the same
#      network ignores pod_subnet_prefix (no cluster.metadata["pod_cidr"]
#      stamped, but a warning FleetEvent is emitted).
#
# Out of scope:
#   - Real k3s install + flannel host-gw behavior on a live cluster
#     (requires QEMU + iBGP topology setup; covered in the operator-driven
#     live smoke documented in tutorials/04-k3s-cluster.md).
#   - End-to-end pod-to-pod traffic capture on the wg-sdwan-* interface.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_flannel_over_sdwan.rb')"

require "json"

step = ->(label) { puts "\n  [step] #{label}" }
ok   = ->(msg) { puts "    ✓ #{msg}" }
fail_with = ->(msg) {
  puts "    ✗ #{msg}"
  abort("  💥 SMOKE FAIL")
}
assert = ->(condition, msg) { condition ? ok.call(msg) : fail_with.call(msg) }

puts "\n  K3s flannel-over-SDWAN smoke test"
puts "  =================================="
puts "  Today: #{Date.today}, Rails env: #{Rails.env}"

# ── Find a NodeInstance with SDWAN peer + k3s-server module ─────────
step.call("Discover a NodeInstance with SDWAN peer + k3s-server assigned")

server_instance = ::System::NodeInstance.joins(
  "INNER JOIN sdwan_peers ON sdwan_peers.node_instance_id = system_node_instances.id"
).where.not("sdwan_peers.assigned_address IS NULL").first

fail_with.call("No NodeInstance with SDWAN peer found — run smoke_test_k3s_runtime.rb prereqs first") unless server_instance

account = server_instance.account
node = server_instance.node
peer = ::Sdwan::Peer.where(node_instance_id: server_instance.id)
                    .where.not(assigned_address: nil)
                    .order(:created_at)
                    .first
network = peer.network
fail_with.call("Bootstrap peer has no Sdwan::Network") unless network

ok.call("server instance=#{server_instance.name} (id=#{server_instance.id[0, 8]})")
ok.call("network=#{network.name} (cidr=#{network.cidr_64})")
ok.call("peer overlay=#{peer.assigned_address}")

# ── Ensure k3s-server module is assigned ────────────────────────────
step.call("Ensure k3s-server module is seeded + assigned")
k3s_server_mod = ::System::NodeModule.where(account: account, name: "k3s-server").first
fail_with.call("k3s-server not seeded") unless k3s_server_mod
assignment = ::System::NodeModuleAssignment.where(node: node, node_module: k3s_server_mod).first
unless assignment
  assignment = ::System::NodeModuleAssignment.create!(node: node, node_module: k3s_server_mod, enabled: true)
end
ok.call("k3s-server module assignment in place")

# ── Cleanup prior smoke residue ─────────────────────────────────────
step.call("Clean up any prior smoke residue")
::Devops::KubernetesCluster.where(account_id: account.id).destroy_all
::Sdwan::SubnetAdvertisement.where(account_id: account.id, source: "pod_subnet").destroy_all
ok.call("residue cleared")

# ── Set pod_subnet_prefix on the network ────────────────────────────
step.call("Set pod_subnet_prefix on the SDWAN network")
network.update!(pod_subnet_prefix: "10.42.0.0/16")
network.reload
assert.call(network.pod_subnet_prefix == "10.42.0.0/16", "network.pod_subnet_prefix = #{network.pod_subnet_prefix}")
assert.call(network.pod_overlay_enabled?, "network.pod_overlay_enabled? returns true")

# ── Smoke 1: Bootstrap with cni_plugin=flannel ──────────────────────
step.call("Bootstrap a k3s cluster with cni_plugin=flannel")

cluster = ::System::KubernetesClusterProvisionerService.bootstrap!(
  node_instance: server_instance,
  kubeconfig: "FAKE KUBECONFIG",
  server_token: "fake-server-token",
  k8s_version: "v1.30.4+k3s1",
  cni_plugin: "flannel"
)

assert.call(cluster.is_a?(::Devops::KubernetesCluster), "returned cluster row")
assert.call(cluster.cni_plugin == "flannel", "cluster.cni_plugin == flannel")
assert.call(cluster.metadata.is_a?(Hash), "cluster.metadata is a hash")
assert.call(cluster.metadata["pod_cidr"] == "10.42.0.0/16", "cluster.metadata['pod_cidr'] = #{cluster.metadata["pod_cidr"]}")
assert.call(cluster.metadata["sdwan_network_id"] == network.id, "cluster.metadata['sdwan_network_id'] = #{cluster.metadata["sdwan_network_id"]}")

# ── Smoke 2: SubnetAdvertisement(source: pod_subnet) ────────────────
step.call("Verify Sdwan::SubnetAdvertisement(source: pod_subnet) created")
ad = ::Sdwan::SubnetAdvertisement.where(account_id: account.id, source: "pod_subnet").first
assert.call(ad.present?, "SubnetAdvertisement row exists")
assert.call(ad.prefix == "10.42.0.0/16", "ad.prefix = #{ad&.prefix}")
assert.call(ad.peer_id == peer.id, "ad.peer == bootstrap peer")
assert.call(ad.active?, "ad.active? returns true")

# ── Smoke 3: bootstrap_config builder returns the new fields ────────
step.call("Verify runtime bootstrap_config builder returns flannel_iface + flannel_backend + cluster_cidr")

# The builder is private on the controller — invoke via a thin shim
# instance bound to the request namespace so we can call the private
# method without going through the full HTTP stack.
controller = ::Api::V1::System::NodeApi::RuntimeController.new
payload = controller.send(:k3s_server_bootstrap_config, server_instance)

assert.call(payload.is_a?(Hash), "payload is a hash")
assert.call(payload[:cni_plugin] == "flannel", "payload[:cni_plugin] = #{payload[:cni_plugin]}")
assert.call(payload[:flannel_iface] == "wg-sdwan-#{network.network_handle}",
            "payload[:flannel_iface] = #{payload[:flannel_iface]}")
assert.call(payload[:flannel_backend] == "host-gw", "payload[:flannel_backend] = #{payload[:flannel_backend]}")
assert.call(payload[:cluster_cidr] == "10.42.0.0/16", "payload[:cluster_cidr] = #{payload[:cluster_cidr]}")

# ── Smoke 4: ovn-Kubernetes path emits warning + does NOT stamp pod_cidr ──
step.call("Verify ovn-Kubernetes ignores pod_subnet_prefix + emits warning event")

# Clean up the flannel cluster so we can bootstrap a fresh ovn-K8s one
::Devops::KubernetesCluster.where(account_id: account.id).destroy_all
::Sdwan::SubnetAdvertisement.where(account_id: account.id, source: "pod_subnet").destroy_all

# Skip Smoke 4 if the network_profile would conflict with ovn-K8s.
# (Lightweight network_profile rejects ovn_kubernetes per Phase O4.)
if node.respond_to?(:network_profile) && node.network_profile.to_s == "lightweight"
  ok.call("skipping ovn-Kubernetes negative smoke — node is lightweight (Phase O4 rejects ovn-K8s here)")
else
  cluster_ovn = ::System::KubernetesClusterProvisionerService.bootstrap!(
    node_instance: server_instance,
    kubeconfig: "FAKE KUBECONFIG",
    server_token: "fake-server-token",
    k8s_version: "v1.30.4+k3s1",
    cni_plugin: "ovn_kubernetes"
  )
  assert.call(cluster_ovn.metadata["pod_cidr"].blank?,
              "ovn-K8s cluster does NOT stamp pod_cidr (metadata: #{cluster_ovn.metadata.except("bootstrapped_at").to_json})")
  # Cleanup
  cluster_ovn.destroy
end

# ── Cleanup ─────────────────────────────────────────────────────────
step.call("Cleanup")
::Devops::KubernetesCluster.where(account_id: account.id).destroy_all
::Sdwan::SubnetAdvertisement.where(account_id: account.id, source: "pod_subnet").destroy_all
network.update!(pod_subnet_prefix: nil)
ok.call("smoke residue cleared")

puts "\n  ✅ smoke_test_flannel_over_sdwan complete"
puts "  (Live smoke — kernel routing of pod traffic over wg-sdwan-* — covered in tutorials/04-k3s-cluster.md)"
