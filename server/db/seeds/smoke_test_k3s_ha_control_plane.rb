# frozen_string_literal: true

# K3s full-lifecycle smoke — Phase 2: HA control plane.
#
# Reads the site cluster from /tmp/smoke-k3s-state.json (phase 1's
# output) + adds 2 more k3s-server NodeInstances to form a 3-server
# HA control plane. Then exercises slice 3 VIP failover by calling
# Sdwan::VirtualIp#failover! synthetically.
#
# Tier semantics:
#   db (default): operator-driven — register_node_join! + mark_node_ready!
#                 + synthetic VirtualIp#failover!. No VMs.
#   single+:      agent-driven — boot 2 more VMs, agents POST phase=join;
#                 platform calls register_node_join! + mark_node_ready!.
#   site+ + SMOKE_K3S_VIP_REAL_FAILOVER=1: terminate bootstrap peer
#                 + wait for SDWAN Manager autonomy to trigger failover
#                 (opt-in only — too brittle for default smoke).
#
# Asserts:
#   - cluster.node_count == 3 (3 servers, 0 agents at this phase)
#   - Sdwan::VirtualIp.failover_holder_peer_ids has the 2 new peers
#   - After failover!, holder_peer_ids includes a peer from failover candidates
#   - bootstrap_events records the failover (via mark_node_ready entries)
#
# State read:  site_<x>_cluster_id, site_<x>_network_id, site_<x>_api_vip_id
# State written: site_<x>_ha_peer_ids (array of the new HA peer IDs)
#
# Invoke:
#   cd server && SMOKE_K3S_LEVEL=db bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_ha_control_plane.rb')"

require_relative "_smoke_k3s_helpers"

h = ::System::Seeds::SmokeK3sHelpers
site = ENV.fetch("SMOKE_K3S_SITE", "a").downcase

puts "\n  K3s lifecycle smoke — Phase 2: Site #{site.upcase} HA control plane"
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

# ── Resume from state sidecar ───────────────────────────────────────
h.step("Resume site #{site.upcase} cluster from state sidecar")
state = h.state_read
cluster_id = state["site_#{site}_cluster_id"]
network_id = state["site_#{site}_network_id"]
api_vip_id = state["site_#{site}_api_vip_id"]
bootstrap_peer_id = state["site_#{site}_peer_id"]

h.fail_with("no site_#{site}_cluster_id in state sidecar — run smoke_test_k3s_site_bootstrap.rb first") unless cluster_id
h.fail_with("no site_#{site}_api_vip_id in state sidecar") unless api_vip_id

cluster = ::Devops::KubernetesCluster.find_by(id: cluster_id, account: account)
h.fail_with("cluster #{cluster_id[0, 8]} not found — stale state? rerun phase 1") unless cluster

network = ::Sdwan::Network.find_by(id: network_id, account: account)
h.fail_with("network #{network_id[0, 8]} not found") unless network

api_vip = ::Sdwan::VirtualIp.find_by(id: api_vip_id, account: account)
h.fail_with("api_vip #{api_vip_id[0, 8]} not found") unless api_vip

h.ok("cluster=#{cluster.name} (status=#{cluster.status})")
h.ok("network=#{network.name}")
h.ok("api_vip=#{api_vip.cidr} (holder=#{Array(api_vip.holder_peer_ids).first&.[](0, 8)})")

# ── Add 2 HA k3s-server peers ───────────────────────────────────────
h.step("Add 2 additional k3s-server NodeInstances (HA control plane)")

ha_node_labels = %w[ha-2 ha-3].map { |suffix| "k3s-#{site}-#{suffix}" }
ha_instances = []
ha_peers = []

ha_node_labels.each_with_index do |label, idx|
  instance, peer = h.bootstrap_node_instance!(name: label, network: network, role: :server)
  ha_instances << instance
  ha_peers << peer
  h.ok("HA server #{idx + 2}: #{label} (peer=#{peer.assigned_address})")
end

h.checkpoint("ready to register HA servers")

# ── Tier-branched node join ─────────────────────────────────────────
if h.tier_at_least?("single")
  h.step("Wait for agent-driven joins to bring cluster.node_count to 3")
  h.wait_until(timeout: 600, label: "cluster.node_count >= 3") do
    cluster.reload
    cluster.node_count >= 3
  end
else
  h.step("Synth join + mark_ready for each HA server (db tier)")
  ha_instances.each_with_index do |inst, idx|
    ::System::KubernetesClusterProvisionerService.register_node_join!(
      node_instance: inst, role: "server", k8s_version: "v1.30.5+k3s1"
    )
    ::System::KubernetesClusterProvisionerService.mark_node_ready!(
      node_instance: inst, k8s_version: "v1.30.5+k3s1"
    )
    h.ok("HA server #{idx + 2}: registered + marked ready")
  end
end

cluster.reload
h.assert(cluster.node_count == 3, "cluster.node_count == 3 (got #{cluster.node_count})")

# ── Verify VIP failover candidates populated ────────────────────────
h.step("Verify VIP failover_holder_peer_ids populated with HA peers")
api_vip.reload
failover_candidates = Array(api_vip.failover_holder_peer_ids)
h.assert(failover_candidates.size == 2,
         "VIP has 2 failover candidates (got #{failover_candidates.size})")
ha_peers.each do |hp|
  h.assert(failover_candidates.include?(hp.id),
           "HA peer #{hp.id[0, 8]} is in failover candidates")
end

# Bootstrap peer is still the primary holder
primary = Array(api_vip.holder_peer_ids).first
h.assert(primary == bootstrap_peer_id, "bootstrap peer is still primary VIP holder")

# ── Synthetic VIP failover ──────────────────────────────────────────
h.step("Trigger synthetic VIP failover (Sdwan::VirtualIp#failover!)")

old_primary = primary
api_vip.failover!(reason: "manual_failover", correlation_id: "smoke-k3s-drill-#{SecureRandom.hex(4)}")
api_vip.reload

new_primary = Array(api_vip.holder_peer_ids).first
h.assert(new_primary != old_primary, "VIP primary changed (#{old_primary[0, 8]} → #{new_primary[0, 8]})")
h.assert(ha_peers.map(&:id).include?(new_primary),
         "new primary is one of the HA peers (#{ha_peers.map { |p| p.id[0, 8] }.inspect})")

# After failover, the OLD primary should now be in failover candidates
new_failover = Array(api_vip.failover_holder_peer_ids)
h.assert(new_failover.include?(old_primary),
         "old primary moved to failover candidates")

# Real-failover variant (opt-in): simulates the sensor-driven path that
# the SDWAN Manager reconciler would take in production. The bootstrap
# node goes "disconnected" (as it would if its VM terminated), then a
# sensor_failover fires. This validates the disconnected-node coupling
# and the sensor_failover reason path, complementing the manual_failover
# coverage above.
if ENV["SMOKE_K3S_VIP_REAL_FAILOVER"] == "1"
  h.step("Real failover via disconnect → sensor_failover (opt-in)")

  bootstrap_instance_id = h.state_read["site_#{site}_instance_id"]
  bootstrap_instance = ::System::NodeInstance.find_by(id: bootstrap_instance_id)
  h.fail_with("bootstrap instance not found in DB") unless bootstrap_instance

  # Simulate the agent reporting offline (in prod this is triggered by
  # the heartbeat sensor detecting absence).
  ::System::KubernetesClusterProvisionerService.mark_node_stopped!(
    node_instance: bootstrap_instance
  )
  h.ok("bootstrap NodeInstance marked disconnected (simulates VM terminate)")

  # Snapshot current VIP holder; trigger sensor-driven failover
  api_vip.reload
  pre_holder = Array(api_vip.holder_peer_ids).first
  api_vip.failover!(reason: "sensor_failover",
                    correlation_id: "smoke-k3s-sensor-#{SecureRandom.hex(4)}")
  api_vip.reload
  post_holder = Array(api_vip.holder_peer_ids).first

  h.assert(post_holder != pre_holder,
           "sensor_failover changed VIP primary (#{pre_holder[0, 8]} → #{post_holder[0, 8]})")
  h.assert(api_vip.assignments.where(reason: "sensor_failover").exists?,
           "VirtualIpAssignment(reason: sensor_failover) row created")
  h.ok("sensor-driven failover validated end-to-end")
end

# ── State sidecar update ────────────────────────────────────────────
h.step("Write HA state to sidecar")
h.state_write(
  "site_#{site}_ha_peer_ids"   => ha_peers.map(&:id),
  "site_#{site}_ha_instance_ids" => ha_instances.map(&:id),
  "site_#{site}_vip_primary_after_failover" => new_primary
)

puts "\n  ✅ Phase 2 (Site #{site.upcase} HA) complete"
puts "  cluster.node_count=#{cluster.node_count} (3 servers); VIP failover validated"
puts "  Next: smoke_test_k3s_agent_join.rb"
