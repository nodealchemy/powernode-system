# frozen_string_literal: true

# K3s full-lifecycle smoke — Phase 4: Pod plane verification.
#
# At db tier: validates the runtime bootstrap_config payload that an
# agent would consume to install k3s with flannel host-gw routing pod
# traffic over the SDWAN overlay. Asserts flannel_iface, flannel_backend,
# cluster_cidr all match the network's pod_subnet_prefix and the
# wg-sdwan-* interface name.
#
# At site+ tier: additionally deploys a 2-replica nginx Deployment, sshs
# into one pod, hits the other pod's IP via wget, and captures tcpdump
# on wg-sdwan-<network_handle> on a Site host to confirm pod traffic
# actually flows over the encrypted SDWAN tunnel. This is the headline
# verification for the 2026-05-19 flannel-over-SDWAN feature.
#
# Tier semantics:
#   db (default): bootstrap_config + DB state only. ~3s.
#   site+:        kubectl deploy + tcpdump on wg-sdwan-*. Requires
#                 kubectl binary + reachable api_endpoint + tcpdump
#                 sudo (typically run from a SDWAN-attached host).
#
# Asserts (db tier):
#   - cluster.metadata['pod_cidr'] matches the network's pod_subnet_prefix
#   - cluster.metadata['sdwan_network_id'] matches the network
#   - runtime bootstrap_config returns flannel_iface=wg-sdwan-<handle>
#   - bootstrap_config returns flannel_backend=host-gw
#   - bootstrap_config returns cluster_cidr=<pod_subnet_prefix>
#   - Sdwan::SubnetAdvertisement(source: pod_subnet) row still active
#
# Asserts (site+ tier):
#   - nginx Deployment reaches 2 ready replicas
#   - Pod A on Node X can wget Pod B's IP on Node Y (cross-node)
#   - tcpdump on wg-sdwan-<handle> captures the wget traffic
#
# Invoke:
#   cd server && SMOKE_K3S_LEVEL=db bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_pod_plane.rb')"

require_relative "_smoke_k3s_helpers"

h = ::System::Seeds::SmokeK3sHelpers
site = ENV.fetch("SMOKE_K3S_SITE", "a").downcase

puts "\n  K3s lifecycle smoke — Phase 4: Site #{site.upcase} pod plane"
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

# ── Resume from sidecar ─────────────────────────────────────────────
state = h.state_read
cluster_id = state["site_#{site}_cluster_id"]
network_id = state["site_#{site}_network_id"]
instance_id = state["site_#{site}_instance_id"]
pod_cidr_expected = state["site_#{site}_pod_cidr"]

h.fail_with("missing state — run phases 1+2+3 first") unless cluster_id && network_id && instance_id

cluster = ::Devops::KubernetesCluster.find_by(id: cluster_id, account: account)
network = ::Sdwan::Network.find_by(id: network_id, account: account)
instance = ::System::NodeInstance.find_by(id: instance_id)
h.fail_with("cluster/network/instance not found — stale state?") unless cluster && network && instance

h.ok("cluster=#{cluster.name} cni=#{cluster.cni_plugin}")
h.ok("network=#{network.name} (handle=#{network.network_handle} pod_subnet_prefix=#{network.pod_subnet_prefix})")

# ── DB-tier: bootstrap_config payload validation ────────────────────
h.step("Verify runtime bootstrap_config payload (the agent's contract for k3s install)")

# Invoke the private controller method via send — matches the pattern in
# smoke_test_flannel_over_sdwan.rb.
controller = ::Api::V1::System::NodeApi::RuntimeController.new
payload = controller.send(:k3s_server_bootstrap_config, instance)

h.assert(payload.is_a?(Hash), "bootstrap_config returns a hash")
h.assert(payload[:cni_plugin] == "flannel", "bootstrap_config[:cni_plugin] == flannel (got #{payload[:cni_plugin]})")
expected_iface = "wg-sdwan-#{network.network_handle}"
h.assert(payload[:flannel_iface] == expected_iface,
         "bootstrap_config[:flannel_iface] == #{expected_iface} (got #{payload[:flannel_iface]})")
h.assert(payload[:flannel_backend] == "host-gw",
         "bootstrap_config[:flannel_backend] == host-gw (got #{payload[:flannel_backend]})")
h.assert(payload[:cluster_cidr] == pod_cidr_expected,
         "bootstrap_config[:cluster_cidr] == #{pod_cidr_expected} (got #{payload[:cluster_cidr]})")

# ── SubnetAdvertisement still active ────────────────────────────────
h.step("Verify pod_subnet SubnetAdvertisement still active")
ad = ::Sdwan::SubnetAdvertisement.where(account: account, sdwan_network_id: network.id,
                                         source: "pod_subnet").order(:created_at).last
h.assert(ad.present?, "Sdwan::SubnetAdvertisement(source: pod_subnet) exists")
h.assert(ad.active?, "advertisement is active")
h.assert(ad.prefix == pod_cidr_expected, "advertisement prefix = #{pod_cidr_expected}")

# ── DB-tier: cluster metadata consistency check ─────────────────────
h.step("Verify cluster metadata + node_count consistent with phases 1-3")
h.assert(cluster.metadata["pod_cidr"] == pod_cidr_expected, "cluster.metadata['pod_cidr'] still correct")
h.assert(cluster.metadata["sdwan_network_id"] == network.id, "cluster.metadata['sdwan_network_id'] still correct")
h.assert(cluster.node_count == 5, "cluster.node_count == 5 (got #{cluster.node_count})")

# ── Site+ tier: kubectl deploy + tcpdump ────────────────────────────
if h.tier_at_least?("site")
  h.step("Live pod-to-pod verification via kubectl + tcpdump on wg-sdwan-*")

  h.fail_with("kubectl binary not found in PATH (override via SMOKE_K3S_KUBECTL)") unless h.kubectl_available?

  kubeconfig_path = "/tmp/k3s-smoke-kubeconfig-#{site}"
  h.fetch_kubeconfig!(cluster: cluster, user: account.users.first, dest_path: kubeconfig_path)
  h.ok("kubeconfig written to #{kubeconfig_path}")

  # Deploy a 2-replica nginx Deployment with podAntiAffinity to force the
  # replicas onto different nodes — that's what exercises cross-node pod
  # routing over flannel host-gw and validates the SDWAN overlay path.
  deploy_yaml = <<~YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata: { name: smoke-nginx, namespace: default }
    spec:
      replicas: 2
      selector: { matchLabels: { app: smoke-nginx } }
      template:
        metadata: { labels: { app: smoke-nginx } }
        spec:
          containers:
          - name: nginx
            image: nginx:alpine
            ports: [{ containerPort: 80 }]
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector: { matchLabels: { app: smoke-nginx } }
                topologyKey: kubernetes.io/hostname
  YAML
  h.kubectl_apply!(kubeconfig: kubeconfig_path, yaml: deploy_yaml)
  h.ok("Deployment applied; waiting for 2 ready replicas")
  h.wait_for_pods_ready!(kubeconfig: kubeconfig_path, label: "app=smoke-nginx", count: 2, timeout: 180)

  pods = h.pod_ips_by_node(kubeconfig: kubeconfig_path, label: "app=smoke-nginx")
  h.assert(pods.size == 2, "2 nginx pods discovered (got #{pods.size})")
  h.assert(pods[0][:node_name] != pods[1][:node_name],
           "pods landed on different nodes (#{pods.map { |p| p[:node_name] }.inspect})")

  pod_a, pod_b = pods
  h.ok("pod A: #{pod_a[:name]}@#{pod_a[:node_name]} ip=#{pod_a[:ip]}")
  h.ok("pod B: #{pod_b[:name]}@#{pod_b[:node_name]} ip=#{pod_b[:ip]}")

  # Start tcpdump on wg-sdwan-<handle> in the background, capturing
  # only packets between the two pod IPs. Then trigger traffic from
  # pod A → pod B. Cleanup: stop tcpdump and count packets.
  iface = "wg-sdwan-#{network.network_handle}"
  filter = "host #{pod_a[:ip]} and host #{pod_b[:ip]}"
  h.step("Start tcpdump on #{iface} filtering #{filter}")
  pid, log_path = h.tcpdump_in_background!(iface: iface, packet_count: 30, filter: filter)
  begin
    h.ok("tcpdump pid=#{pid} log=#{log_path}")

    # Drive cross-node traffic
    h.step("Trigger pod A → pod B HTTP request")
    system("#{h.kubectl_binary} --kubeconfig=#{kubeconfig_path} exec #{pod_a[:name]} -- wget -qO- " \
           "--timeout=5 http://#{pod_b[:ip]} > /dev/null 2>&1")
    # Give tcpdump a moment to flush
    sleep 2
  ensure
    h.tcpdump_stop(pid: pid)
  end

  packet_count = h.tcpdump_count(log_path: log_path)
  h.assert(packet_count > 0,
           "tcpdump captured #{packet_count} packets on #{iface} — pod traffic flowed over SDWAN overlay")

  # Cleanup
  h.step("Tear down nginx Deployment + capture log")
  h.kubectl_delete!(kubeconfig: kubeconfig_path, resource: "deploy smoke-nginx")
  File.delete(log_path) if File.exist?(log_path)
  h.ok("nginx Deployment torn down")
else
  h.ok("kubectl + tcpdump live tests skipped (current tier: #{h.current_tier})")
end

puts "\n  ✅ Phase 4 (Site #{site.upcase} pod plane) complete"
puts "  flannel_iface=wg-sdwan-#{network.network_handle} flannel_backend=host-gw cluster_cidr=#{pod_cidr_expected}"
puts "  Next: SMOKE_K3S_SITE=b for Site B, or smoke_test_k3s_federation.rb"
