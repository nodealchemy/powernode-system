# frozen_string_literal: true

# K3s full-lifecycle smoke — Phase 1: Site bootstrap.
#
# First phase of the 9-phase K3s lifecycle smoke (see runbooks/
# k3s-smoke-full-lifecycle.md). Stands up an SDWAN network with
# pod_subnet_prefix set and bootstraps a single k3s-server cluster
# on it. Site-parameterizable via SMOKE_K3S_SITE=a|b.
#
# Site A: pod_subnet_prefix=172.30.0.0/16, network handle=k3s-site-a
# Site B: pod_subnet_prefix=172.31.0.0/16, network handle=k3s-site-b
#
# Defaults are non-k3s-standard intentionally (k3s defaults to 10.42/16,
# which often conflicts with existing dev DB state). Override via
# SMOKE_K3S_POD_PREFIX_A / SMOKE_K3S_POD_PREFIX_B if you have specific
# routing constraints.
#
# Tier semantics (see _smoke_k3s_helpers.rb for full table):
#   db (default): operator-driven — calls KubernetesClusterProvisionerService.bootstrap!
#                 directly. No VM boot. ~30s per phase.
#   single+:      agent-driven — boots VM via LocalQemuProvider; the on-VM
#                 Go agent POSTs phase=bootstrap to runtime_controller,
#                 which calls bootstrap!. Seed polls cluster status.
#
# Asserts:
#   - SDWAN network created with pod_subnet_prefix set
#   - K3s cluster reaches status=active
#   - cluster.metadata["pod_cidr"] matches the site's pod_subnet_prefix
#   - cluster.metadata["sdwan_network_id"] matches the network
#   - cluster.metadata["api_vip_id"] is populated (single-holder VIP)
#   - cluster.metadata["bootstrap_events"] has at least one entry
#   - Sdwan::SubnetAdvertisement(source: pod_subnet) row created
#
# State written to /tmp/smoke-k3s-state.json:
#   site_a_cluster_id (or site_b_cluster_id)
#   site_a_network_id (or site_b_network_id)
#   site_a_instance_id (or site_b_instance_id)
#   site_a_peer_id (or site_b_peer_id)
#
# Invoke:
#   cd server && SMOKE_K3S_LEVEL=db bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_site_bootstrap.rb')"

require_relative "_smoke_k3s_helpers"

h = ::System::Seeds::SmokeK3sHelpers

site = ENV.fetch("SMOKE_K3S_SITE", "a").downcase
unless %w[a b].include?(site)
  abort("  ✗ SMOKE_K3S_SITE must be 'a' or 'b' (got #{site.inspect})")
end
default_prefix = (site == "a" ? "172.30.0.0/16" : "172.31.0.0/16")
pod_prefix     = ENV.fetch("SMOKE_K3S_POD_PREFIX_#{site.upcase}", default_prefix)
network_name   = "k3s-site-#{site}"
cluster_label  = "k3s-#{site}-bootstrap"

puts "\n  K3s lifecycle smoke — Phase 1: Site #{site.upcase} bootstrap"
puts "  ============================================================"
puts "  Tier:           #{h.current_tier}"
puts "  Pod prefix:     #{pod_prefix}"
puts "  Network name:   #{network_name}"
puts "  Today: #{Date.today}, Rails env: #{Rails.env}"

begin
  h.tier_gate(required: "db")  # phase 1 floor
rescue ::System::Seeds::SmokeK3sHelpers::TierInsufficient => e
  h.skipped(e.message)
  exit 0
end

h.preflight!(level: h.current_tier)
account = h.discover_or_create_account!
h.ok("account=#{account.name} (id=#{account.id[0, 8]})")

# ── Site SDWAN network with pod_subnet_prefix ───────────────────────
h.step("Find or create SDWAN network #{network_name}")
network = ::Sdwan::Network.find_or_initialize_by(account_id: account.id, name: network_name)
if network.new_record?
  network.routing_protocol = "static"
  network.pod_subnet_prefix = pod_prefix
  network.save!
  h.ok("network created (id=#{network.id[0, 8]} pod_subnet_prefix=#{network.pod_subnet_prefix})")
else
  # Re-runs: ensure pod_subnet_prefix is set; never overwrite a different value
  if network.pod_subnet_prefix.blank?
    network.update!(pod_subnet_prefix: pod_prefix)
    h.ok("network present; stamped pod_subnet_prefix=#{pod_prefix}")
  elsif network.pod_subnet_prefix != pod_prefix
    h.fail_with("network #{network_name} already has pod_subnet_prefix=#{network.pod_subnet_prefix}, " \
                "expected #{pod_prefix}. Manually reset or use SMOKE_K3S_AUTO_CLEAN=1.")
  else
    h.ok("network present (pod_subnet_prefix=#{network.pod_subnet_prefix})")
  end
end

h.assert(network.pod_subnet_prefix == pod_prefix, "network.pod_subnet_prefix = #{pod_prefix}")

# ── Node + NodeInstance + Sdwan::Peer + module assignment ───────────
h.step("Bootstrap Node + NodeInstance + SDWAN peer for #{cluster_label}")
instance, peer = h.bootstrap_node_instance!(name: cluster_label, network: network, role: :server)
h.ok("instance=#{instance.name} (id=#{instance.id[0, 8]})")
h.ok("peer=#{peer.id[0, 8]} (network=#{network.name})")

# Ensure the peer has an assigned_address. At db tier the SDWAN allocator
# runs on Peer create; on re-runs the address persists.
peer.reload
if peer.assigned_address.blank?
  h.fail_with("peer #{peer.id} has no assigned_address — SDWAN allocator may have skipped " \
              "(check Sdwan::Network allocator config or seed Sdwan::Network with a usable cidr_64)")
end
h.ok("peer assigned_address=#{peer.assigned_address}")

h.checkpoint("ready to bootstrap cluster")

# ── Tier-branched bootstrap ─────────────────────────────────────────
cluster = h.run_bootstrap_phase(
  account:    account,
  instance:   instance,
  network:    network,
  cni_plugin: "flannel"
)

# ── Assertions on the bootstrap result ──────────────────────────────
h.step("Verify cluster bootstrap stamped expected metadata")

h.assert(cluster.is_a?(::Devops::KubernetesCluster), "bootstrap returned a Devops::KubernetesCluster")
h.assert(cluster.flavor == "k3s", "cluster.flavor == k3s (got #{cluster.flavor})")
h.assert(cluster.cni_plugin == "flannel", "cluster.cni_plugin == flannel (got #{cluster.cni_plugin})")

# At db tier mark_node_ready was synthesized → status="active". At single+
# tier wait_for_cluster_active polled until status="active".
h.assert(cluster.status == "active", "cluster.status == active (got #{cluster.status})")

h.assert(cluster.metadata["pod_cidr"] == pod_prefix,
         "cluster.metadata['pod_cidr'] = #{pod_prefix} (got #{cluster.metadata["pod_cidr"].inspect})")
h.assert(cluster.metadata["sdwan_network_id"] == network.id,
         "cluster.metadata['sdwan_network_id'] matches network.id")
h.assert(cluster.metadata["api_vip_id"].present?,
         "cluster.metadata['api_vip_id'] populated (got #{cluster.metadata["api_vip_id"].inspect})")

# bootstrap_events (commit 1 instrumentation) — at db tier we have at
# least two events (bootstrap.completed + mark_node_ready.node_ready_cluster_promoted).
events = Array(cluster.metadata["bootstrap_events"])
h.assert(events.size >= 1, "cluster.metadata['bootstrap_events'] has at least 1 entry (got #{events.size})")
phases = events.map { |e| e["phase"] }.uniq
h.assert(phases.include?("bootstrap"), "bootstrap event recorded (phases: #{phases.inspect})")

# VIP allocated + bootstrap peer is primary holder
vip = ::Sdwan::VirtualIp.find_by(id: cluster.metadata["api_vip_id"])
h.assert(vip.present?, "Sdwan::VirtualIp row exists for api_vip_id")
h.assert(vip.state == "active", "VIP state == active (got #{vip.state})")
h.assert(Array(vip.holder_peer_ids).include?(peer.id),
         "bootstrap peer is in VIP holder_peer_ids")

# SubnetAdvertisement(source: pod_subnet) created
ad = ::Sdwan::SubnetAdvertisement.where(account_id: account.id, sdwan_network_id: network.id,
                                         source: "pod_subnet").order(:created_at).last
h.assert(ad.present?, "Sdwan::SubnetAdvertisement(source: pod_subnet) row exists")
h.assert(ad.prefix == pod_prefix, "advertisement prefix = #{pod_prefix}")
h.assert(ad.sdwan_peer_id == peer.id, "advertisement.sdwan_peer_id == bootstrap peer.id")
h.assert(ad.active?, "advertisement is active")

# ── State sidecar write ─────────────────────────────────────────────
h.step("Write phase 1 state to #{::System::Seeds::SmokeK3sHelpers::STATE_PATH}")
state = h.state_write(
  "site_#{site}_cluster_id"  => cluster.id,
  "site_#{site}_network_id"  => network.id,
  "site_#{site}_instance_id" => instance.id,
  "site_#{site}_peer_id"     => peer.id,
  "site_#{site}_api_vip_id"  => cluster.metadata["api_vip_id"],
  "site_#{site}_pod_cidr"    => pod_prefix
)
h.ok("state keys: #{state.keys.grep(/^site_#{site}/).inspect}")

puts "\n  ✅ Phase 1 (Site #{site.upcase}) complete"
puts "  cluster_id=#{cluster.id} status=#{cluster.status} pod_cidr=#{pod_prefix}"
puts "  Next: smoke_test_k3s_ha_control_plane.rb"
