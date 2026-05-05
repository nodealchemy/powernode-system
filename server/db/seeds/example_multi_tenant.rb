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

def ensure_node!(account:, hostname:, lifecycle_class: "persistent")
  node = ::System::Node.find_or_initialize_by(account: account, hostname: hostname)
  node.assign_attributes(
    lifecycle_class: lifecycle_class,
    metadata: { "demo": "example_multi_tenant" }
  )
  node.save!
  node
end

def ensure_sdwan_network!(account:, name:)
  net = ::Sdwan::Network.find_or_initialize_by(account: account, name: name)
  net.assign_attributes(
    description: "Tenant-isolated overlay (example 03)",
    routing_mode: "static",
    status: "active"
  ) if net.new_record?
  net.save!
  net
end

# ── Setup: 2 tenants ──────────────────────────────────────────────────────

tenant_a_node = ensure_node!(account: account, hostname: "tenant-a-host-demo")
tenant_b_node = ensure_node!(account: account, hostname: "tenant-b-host-demo")
puts "  ✅ Nodes: tenant-a-host-demo, tenant-b-host-demo"

network_a = ensure_sdwan_network!(account: account, name: "tenant-a-demo")
network_b = ensure_sdwan_network!(account: account, name: "tenant-b-demo")
puts "  ✅ SDWAN networks: #{network_a.name} (#{network_a.prefix || 'auto-allocated'}), #{network_b.name}"

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

if network_a.prefix && network_b.prefix && network_a.prefix != network_b.prefix
  puts "  ✅ Networks have distinct prefixes — cross-tenant reachability not routed"
else
  puts "  ⚠️  One or both networks lack a prefix — auto-allocation deferred"
end

# Optional: add a default-deny firewall rule on each network to make the boundary
# explicit (defense-in-depth, vs implicit routing-level isolation).
[network_a, network_b].each do |net|
  next unless ::Sdwan::FirewallRule.where(account: account, network: net, action: "drop").none?

  ::Sdwan::FirewallRule.create!(
    account: account,
    network: net,
    direction: "ingress",
    action: "drop",
    selector_kind: "all",
    selector_payload: {},
    protocol: "any",
    priority: 1000
  )
  puts "  ✅ Added default-deny firewall rule on #{net.name}"
end

puts "  Done seeding example_multi_tenant. See docs/examples/03-multi-tenant-container-farm.md."
