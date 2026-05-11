# frozen_string_literal: true

# Companion seed for docs/examples/03-multi-tenant-container-farm.md.
#
# Demonstrates per-tenant Docker hosts on isolated SDWAN networks. Idempotent
# via find_or_create_by!. Platform-side only — does not require LocalQemuProvider
# to actually boot VMs.
#
# Run via:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/example_multi_tenant.rb')"

puts "\n  Seeding example_multi_tenant (Example 03)..."

account = ::Account.first
unless account
  puts "  ⚠️  No account found — skipping"
  return
end

user = account.users.find_by(email: "admin@powernode.org") || account.users.first
unless user
  puts "  ⚠️  No admin user — skipping"
  return
end

# ── Helpers ──────────────────────────────────────────────────────────────

# `system_nodes` exposes `name` (not `hostname`), requires a `node_template`,
# and uses `config` JSONB (no `metadata`).
def ensure_node!(account:, name:, node_template:, lifecycle_class: "persistent")
  node = ::System::Node.find_or_initialize_by(account: account, name: name)
  node.assign_attributes(
    lifecycle_class: lifecycle_class,
    node_template: node_template,
    config: (node.config || {}).merge("source" => "example_multi_tenant")
  )
  node.save!
  node
end

def ensure_sdwan_network!(account:, name:)
  net = ::Sdwan::Network.find_or_initialize_by(account: account, name: name)
  net.assign_attributes(
    description: "Tenant-isolated overlay (example 03)",
    # Schema column is `routing_protocol`, not `routing_mode` — rename
    # post-dated this seed.
    routing_protocol: "static",
    status: "active"
  ) if net.new_record?
  net.save!
  net
end

# ── Setup: 2 tenants ──────────────────────────────────────────────────────

# Provision the prerequisite chain (architecture → platform → template)
# once for both tenant nodes to share.
architecture = ::System::NodeArchitecture.find_by!(account: account, name: "amd64")
platform = ::System::NodePlatform.find_or_create_by!(account: account, name: "ubuntu-24.04") do |p|
  p.node_architecture = architecture
end
node_template = ::System::NodeTemplate.find_or_create_by!(account: account, name: "tenant-baseline") do |t|
  t.node_platform = platform
  t.description = "Baseline template for multi-tenant overlay nodes"
end

tenant_a_node = ensure_node!(account: account, name: "tenant-a-host", node_template: node_template)
tenant_b_node = ensure_node!(account: account, name: "tenant-b-host", node_template: node_template)
puts "  ✅ Nodes: tenant-a-host, tenant-b-host"

network_a = ensure_sdwan_network!(account: account, name: "tenant-a")
network_b = ensure_sdwan_network!(account: account, name: "tenant-b")
puts "  ✅ SDWAN networks: #{network_a.name} (#{network_a.cidr_64 || 'auto-allocated'}), #{network_b.name}"

# ── NodeInstances (skipped — would require provider; see node-provisioning runbook) ──

puts "  ℹ️  NodeInstance provisioning skipped — uses LocalQemuProvider in production demos."
puts "       To run end-to-end:"
puts "       1. POWERNODE_LIBVIRT_MODE=real bundle exec rails runner ..."
puts "       2. system_provision_instance for each Node (via MCP)"
puts "       3. system_sdwan_attach_peer to bind each instance to its tenant network"
puts "       4. system_provision_docker_runtime to provision Docker on each"

# ── Verify isolation premise ──────────────────────────────────────────────

# The two networks have non-overlapping /64 prefixes, so cross-network reachability
# is implicitly blocked at the routing layer — no firewall rule needed for the
# basic isolation guarantee.

if network_a.cidr_64 && network_b.cidr_64 && network_a.cidr_64 != network_b.cidr_64
  puts "  ✅ Networks have distinct /64 prefixes — cross-tenant reachability not routed"
else
  puts "  ⚠️  One or both networks lack a cidr_64 — auto-allocation deferred"
end

# Optional: add a default-deny firewall rule on each network to make the boundary
# explicit (defense-in-depth, vs implicit routing-level isolation).
[network_a, network_b].each do |net|
  next unless ::Sdwan::FirewallRule.where(account: account, network: net, action: "drop").none?

  ::Sdwan::FirewallRule.create!(
    account: account,
    network: net,
    name: "default-deny-ingress",
    direction: "ingress",
    action: "drop",
    # FirewallRule uses src_selector + dst_selector JSONB columns now
    # (no `selector_kind` / `selector_payload` pair). Empty hash = match-all.
    src_selector: {},
    dst_selector: {},
    protocol: "any",
    priority: 1000
  )
  puts "  ✅ Added default-deny firewall rule on #{net.name}"
end

puts "  Done seeding example_multi_tenant. See docs/examples/03-multi-tenant-container-farm.md."
