# frozen_string_literal: true

# System Platform permissions — gates the operator-facing
# /app/system/compute/platform dashboard introduced in P7.
#
# Plan reference: Decentralized Federation §I + P7.

puts "Seeding system.platform.* permissions..."

platform_permissions = [
  { resource: "system.platform", action: "read",
    description: "View the unified Platform dashboard (counts, status, overview)" },
  { resource: "system.platform", action: "scale",
    description: "Draft scaling plans for platform components" },
  { resource: "system.platform.scale", action: "apply",
    description: "Apply a drafted scaling plan (provisions/decommissions instances)" },
  { resource: "system.platform.health", action: "read",
    description: "Read platform health metrics (uptime, queue depth, etc.)" },

  # P7.1 — Peers panel. Distinct from sdwan.federation.* (which gates
  # the legacy SDWAN-only peering surface) so operators can grant
  # platform-peer visibility without exposing the lower-level routing
  # primitives.
  { resource: "system.peers", action: "read",
    description: "View the platform Peers list and per-peer detail" },
  { resource: "system.peers", action: "invite",
    description: "Propose a new federation peer (generates acceptance token)" },
  { resource: "system.peers", action: "manage",
    description: "Manage platform peers (revoke, suspend, resume)" },

  # D1.2 — Deploy new platform (standalone OR federated). Distinct
  # from system.platform.scale (which mutates an existing deployment).
  { resource: "system.platform", action: "deploy",
    description: "Deploy a new Powernode platform (standalone or federated)" }
]

platform_permissions.each do |perm|
  name = "#{perm[:resource]}.#{perm[:action]}"
  Permission.find_or_create_by!(name: name) do |p|
    p.description = perm[:description]
  end
end

puts "  - Created/verified #{platform_permissions.size} permissions"

admin_role = Role.find_by(name: "admin")
if admin_role
  platform_permissions.each do |perm|
    name = "#{perm[:resource]}.#{perm[:action]}"
    permission = Permission.find_by(name: name)
    next unless permission
    next if admin_role.permissions.exists?(id: permission.id)
    admin_role.permissions << permission
  end
  puts "  - Granted to admin role"
end
