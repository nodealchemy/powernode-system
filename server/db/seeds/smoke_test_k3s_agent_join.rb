# frozen_string_literal: true

# K3s full-lifecycle smoke — Phase 3: Agent join.
#
# Reads the site cluster from /tmp/smoke-k3s-state.json + adds 2
# k3s-agent NodeInstances. Verifies node_count reaches 5 (3 servers
# from phase 2 + 2 agents).
#
# Negative test: confirms the Phase O4 CNI profile gate still rejects
# a lightweight NodeInstance joining an ovn_kubernetes cluster. Uses
# a stub Devops::KubernetesCluster (cni_plugin=ovn_kubernetes) — no
# need for a real bootstrap, the check is independent of cluster state.
#
# Tier semantics:
#   db (default): operator-driven register_node_join! + mark_node_ready!
#                 for each agent. Negative test runs always.
#   single+:      agent-driven — VMs boot, agents POST phase=join_request
#                 with target_cluster_id, platform reconciles.
#
# Asserts:
#   - 2 new KubernetesNode rows with role=agent, status=active
#   - cluster.node_count == 5 (3 servers + 2 agents)
#   - CniProfileMismatchError raised when lightweight node joins
#     ovn_kubernetes cluster
#
# Invoke:
#   cd server && SMOKE_K3S_LEVEL=db bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_agent_join.rb')"

require_relative "_smoke_k3s_helpers"

h = ::System::Seeds::SmokeK3sHelpers
site = ENV.fetch("SMOKE_K3S_SITE", "a").downcase

puts "\n  K3s lifecycle smoke — Phase 3: Site #{site.upcase} agent join"
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

# ── Resume cluster from state sidecar ───────────────────────────────
state = h.state_read
cluster_id = state["site_#{site}_cluster_id"]
network_id = state["site_#{site}_network_id"]
h.fail_with("no site_#{site}_cluster_id in state — run phase 1 + 2 first") unless cluster_id

cluster = ::Devops::KubernetesCluster.find_by(id: cluster_id, account: account)
h.fail_with("cluster #{cluster_id[0, 8]} not found in DB") unless cluster
network = ::Sdwan::Network.find_by(id: network_id, account: account)
h.fail_with("network #{network_id[0, 8]} not found") unless network

h.ok("cluster=#{cluster.name} (cni=#{cluster.cni_plugin} node_count=#{cluster.node_count})")
h.ok("network=#{network.name}")

# ── Add 2 k3s-agent NodeInstances ───────────────────────────────────
h.step("Add 2 k3s-agent NodeInstances")

agent_node_labels = %w[agent-1 agent-2].map { |suffix| "k3s-#{site}-#{suffix}" }
agent_instances = []
agent_peers = []

agent_node_labels.each_with_index do |label, idx|
  instance, peer = h.bootstrap_node_instance!(name: label, network: network, role: :agent)
  agent_instances << instance
  agent_peers << peer
  h.ok("agent #{idx + 1}: #{label} (peer=#{peer.assigned_address})")
end

h.checkpoint("ready to register agents")

# ── Tier-branched join ──────────────────────────────────────────────
if h.tier_at_least?("single")
  h.step("Wait for agent-driven joins to bring cluster.node_count to 5")
  h.wait_until(timeout: 600, label: "cluster.node_count >= 5") do
    cluster.reload
    cluster.node_count >= 5
  end
else
  h.step("Synth register_node_join + mark_node_ready for each agent (db tier)")
  agent_instances.each_with_index do |inst, idx|
    join = ::System::KubernetesClusterProvisionerService.join_request!(
      node_instance: inst, target_cluster_id: cluster.id
    )
    h.assert(join[:cluster_id] == cluster.id, "agent #{idx + 1}: join resolves to expected cluster")

    node_row = ::System::KubernetesClusterProvisionerService.register_node_join!(
      node_instance: inst, role: "agent", k8s_version: "v1.30.5+k3s1"
    )
    h.assert(node_row.role == "agent", "agent #{idx + 1}: role=agent")
    h.assert(node_row.status == "joining", "agent #{idx + 1}: initial status=joining")

    ready = ::System::KubernetesClusterProvisionerService.mark_node_ready!(
      node_instance: inst, k8s_version: "v1.30.5+k3s1"
    )
    h.assert(ready.status == "active", "agent #{idx + 1}: marked active")
  end
end

cluster.reload
h.assert(cluster.node_count == 5,
         "cluster.node_count == 5 (3 servers + 2 agents) (got #{cluster.node_count})")

agent_roles = cluster.kubernetes_nodes.where(role: "agent").pluck(:status).sort
h.assert(agent_roles == %w[active active],
         "both agents are status=active (got #{agent_roles.inspect})")

# ── Negative test: lightweight rejected from ovn_kubernetes ─────────
h.step("Negative test: lightweight NodeInstance cannot join ovn_kubernetes cluster")

# Build a stub ovn_kubernetes cluster. We don't go through bootstrap! —
# the CNI profile gate runs independently of cluster bootstrap state.
# Using a synthetic cluster keeps the negative test contained.
stub_cluster_name = "smoke-ovn-rejection-#{SecureRandom.hex(4)}"
stub_cluster = ::Devops::KubernetesCluster.create!(
  account:      account,
  name:         stub_cluster_name,
  flavor:       "k3s",
  environment:  "production",
  status:       "active",
  cni_plugin:   "ovn_kubernetes",
  api_endpoint: "https://[::1]:6443",
  k8s_version:  "v1.30.5+k3s1",
  encrypted_kubeconfig: "stub",
  encrypted_server_token: "stub",
  encrypted_agent_token: "stub",
  metadata: {}
)

# Reuse the first agent NodeInstance as a "lightweight" host. Snap its
# network_profile to lightweight for the duration of the test, restore
# after.
lightweight_inst = agent_instances.first
prior_profile = lightweight_inst.respond_to?(:network_profile) ? lightweight_inst.network_profile : nil
if lightweight_inst.respond_to?(:network_profile=)
  lightweight_inst.update!(network_profile: "lightweight")
end

raised = false
begin
  # Internally calls enforce_cni_profile_compatibility!, but the
  # provisioner's class-level join requires a cluster lookup by account.
  # Since the stub cluster IS in the account, it'll be picked as
  # most-recent. To target the stub deterministically, we instantiate
  # the service directly with the role set.
  service = ::System::KubernetesClusterProvisionerService.new(
    node_instance: lightweight_inst, role: "agent", k8s_version: "v1.30"
  )
  # Force the cluster lookup to find our stub by removing all OTHER
  # active clusters from contention via order(:created_at).last
  # → since stub_cluster was just created, it IS the most recent.
  service.register_node_join!
rescue ::System::KubernetesClusterProvisionerService::CniProfileMismatchError => e
  raised = true
  h.ok("CniProfileMismatchError raised: #{e.message[0, 100]}...")
end

# Restore the agent's profile before asserting (so it stays usable for
# subsequent phases)
if prior_profile.nil? && lightweight_inst.respond_to?(:network_profile=)
  lightweight_inst.update!(network_profile: nil)
elsif lightweight_inst.respond_to?(:network_profile=)
  lightweight_inst.update!(network_profile: prior_profile)
end

# Cleanup stub cluster
stub_cluster.destroy

h.assert(raised, "lightweight host rejected from ovn_kubernetes cluster (CniProfileMismatchError)")

# ── State sidecar update ────────────────────────────────────────────
h.state_write(
  "site_#{site}_agent_peer_ids"     => agent_peers.map(&:id),
  "site_#{site}_agent_instance_ids" => agent_instances.map(&:id)
)

puts "\n  ✅ Phase 3 (Site #{site.upcase} agents) complete"
puts "  cluster.node_count=#{cluster.node_count} (3 servers + 2 agents)"
puts "  CNI rejection negative test verified"
puts "  Next: smoke_test_k3s_pod_plane.rb"
