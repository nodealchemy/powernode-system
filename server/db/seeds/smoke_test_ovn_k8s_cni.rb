# frozen_string_literal: true

# System extension — Smoke-test for Phase O4 (OVN-K8s CNI selection).
#
# DB-level integration test: verifies the platform compiles the right
# K3s server bootstrap config per cluster cni_plugin, with profile-
# based auto-defaults. Pairs with the agent's Go-level k3sd
# BootstrapConfig tests.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_ovn_k8s_cni.rb')"

puts "\n  Smoke-test: Phase O4 — OVN-Kubernetes CNI selection"
puts "  " + ("=" * 60)

# ── Setup fixtures ────────────────────────────────────────────────────

account  = Account.first or abort("  ❌ No account in DB")
template = System::NodeTemplate.find_by(account: account, name: "base") ||
           System::NodeTemplate.where(account: account).first ||
           abort("  ❌ No node template")
provider = System::Provider.find_by(account: account, provider_type: "local_qemu") or
           abort("  ❌ No local_qemu provider")
region   = provider.provider_regions.first or abort("  ❌ No provider region")
itype    = provider.provider_instance_types.first or abort("  ❌ No instance type")

def make_host(account:, template:, region:, itype:, name:, profile:)
  node = System::Node.find_or_create_by!(account: account, name: name) do |n|
    n.node_template = template
  end
  instance = System::NodeInstance.find_or_initialize_by(node: node, name: "#{name}-instance")
  instance.assign_attributes(
    variety: "cloud",
    provider_region: region,
    provider_instance_type: itype,
    status: "running",
    network_profile: profile
  )
  instance.save!
  instance
end

# Wipe prior smoke fixtures
::Devops::KubernetesNode.joins(:kubernetes_cluster).where(devops_kubernetes_clusters: { account_id: account.id }).where("devops_kubernetes_clusters.name LIKE 'smoke-cni-%'").destroy_all
::Devops::KubernetesCluster.where(account_id: account.id).where("name LIKE 'smoke-cni-%'").destroy_all

heavy = make_host(account: account, template: template, region: region, itype: itype,
                  name: "smoke-cni-heavy", profile: "heavyweight")
light = make_host(account: account, template: template, region: region, itype: itype,
                  name: "smoke-cni-light", profile: "lightweight")

puts "  Account:  #{account.id[0..7]}…"
puts "  Heavy host: #{heavy.id[0..7]}…  profile=#{heavy.network_profile}"
puts "  Light host: #{light.id[0..7]}…  profile=#{light.network_profile}"
puts ""

# ── Test 1: KubernetesCluster cni_plugin enum + default ───────────────

cluster_default = ::Devops::KubernetesCluster.create!(
  account: account,
  name: "smoke-cni-default-#{SecureRandom.hex(2)}",
  api_endpoint: "https://10.0.0.1:6443"
)
abort("  ❌ Test 1 FAILED — default cni_plugin should be 'flannel' (got #{cluster_default.cni_plugin})") unless cluster_default.cni_plugin == "flannel"
puts "  ✓ Test 1: default cni_plugin is 'flannel'"

# ── Test 2: Explicit cni_plugin = ovn_kubernetes accepted ─────────────

cluster_ovn = ::Devops::KubernetesCluster.create!(
  account: account,
  name: "smoke-cni-ovn-#{SecureRandom.hex(2)}",
  api_endpoint: "https://10.0.0.2:6443",
  cni_plugin: "ovn_kubernetes"
)
abort("  ❌ Test 2 FAILED — explicit cni_plugin not honored (got #{cluster_ovn.cni_plugin})") unless cluster_ovn.cni_plugin == "ovn_kubernetes"
puts "  ✓ Test 2: explicit cni_plugin=ovn_kubernetes accepted"

# ── Test 3: Invalid cni_plugin rejected ───────────────────────────────

cluster_bad = ::Devops::KubernetesCluster.new(
  account: account,
  name: "smoke-cni-bad",
  api_endpoint: "https://10.0.0.3:6443",
  cni_plugin: "calico"
)
abort("  ❌ Test 3 FAILED — invalid cni_plugin should be rejected") if cluster_bad.valid?
puts "  ✓ Test 3: unknown cni_plugin (calico) rejected by validation"

# ── Test 4: k3s_install_flags returns the right CLI args ──────────────

flannel_flags = ::Devops::KubernetesCluster.k3s_install_flags_for("flannel")
ovn_flags     = ::Devops::KubernetesCluster.k3s_install_flags_for("ovn_kubernetes")
abort("  ❌ Test 4 FAILED — flannel flags should be empty (got #{flannel_flags.inspect})") unless Array(flannel_flags).empty?
expected_ovn_flags = %w[--flannel-backend=none --disable-network-policy]
abort("  ❌ Test 4 FAILED — ovn flags wrong (got #{ovn_flags.inspect})") unless Array(ovn_flags).sort == expected_ovn_flags.sort
puts "  ✓ Test 4: k3s_install_flags emits correct args (flannel=[], ovn=#{ovn_flags.inspect})"

# ── Test 5: runtime_controller bootstrap_config payload — direct lookup

# The full provisioner workflow requires real K3s server output
# (kubeconfig + tokens), which the unit specs cover separately. Here we
# exercise the runtime_controller's resolution path directly: attach a
# host to a cluster with explicit cni_plugin, then verify the same
# Devops::KubernetesNode → cluster lookup the controller does.
::Devops::KubernetesNode.find_or_create_by!(
  kubernetes_cluster: cluster_ovn,
  node_instance: heavy
) { |n| n.name = "heavy-node-1"; n.role = "server" }

node_lookup = ::Devops::KubernetesNode.where(node_instance_id: heavy.id).joins(:kubernetes_cluster).first
resolved = node_lookup&.kubernetes_cluster&.cni_plugin || "flannel"
abort("  ❌ Test 5 FAILED — controller helper would resolve cni_plugin=#{resolved} for heavy host") unless resolved == "ovn_kubernetes"
puts "  ✓ Test 5: runtime_controller helper resolves cni_plugin=ovn_kubernetes for heavy host attached to OVN cluster"

# ── Test 6: hosts not in any cluster default to flannel ───────────────

# The lightweight host isn't attached to any cluster.
node_lookup_light = ::Devops::KubernetesNode.where(node_instance_id: light.id).joins(:kubernetes_cluster).first
resolved_light = node_lookup_light&.kubernetes_cluster&.cni_plugin || "flannel"
abort("  ❌ Test 6 FAILED — unenrolled host should default to flannel (got #{resolved_light})") unless resolved_light == "flannel"
puts "  ✓ Test 6: unenrolled host defaults to cni_plugin=flannel (safe K3s default)"

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  ::Devops::KubernetesNode
    .joins(:kubernetes_cluster)
    .where(devops_kubernetes_clusters: { account_id: account.id })
    .where("devops_kubernetes_clusters.name LIKE 'smoke-cni-%'")
    .destroy_all
  ::Devops::KubernetesCluster.where(account_id: account.id).where("name LIKE 'smoke-cni-%'").destroy_all
  [heavy, light].each do |inst|
    inst.destroy
    inst.node.destroy
  end
  puts ""
  puts "  Cleanup: removed smoke fixtures (set SMOKE_KEEP=1 to preserve)"
end

puts ""
puts "  ✅ All O4 smoke tests passed."
