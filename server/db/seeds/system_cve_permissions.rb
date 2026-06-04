# frozen_string_literal: true

# System CVE permissions — gate the operator-facing CVE exposure read API
# (Api::V1::System::CveExposuresController).
#
# CVE exposures are produced by the worker-side feed ingest + CVE Responder
# autonomy loop; these permissions only govern the operator read surface.
# `manage` is reserved for a future operator-initiated triage/dismiss write
# path (today remediation flows through the CVE Responder agent), but is
# seeded now so the role grants are already in place when that lands.

puts "Seeding system.cve.* permissions..."

system_cve_permissions = [
  { resource: "system.cve", action: "read",
    description: "View CVE exposures across the fleet (severity, state, affected modules)" },
  { resource: "system.cve", action: "manage",
    description: "Triage CVE exposures (mark remediating / resolved / wont_fix)" }
]

system_cve_permissions.each do |perm|
  name = "#{perm[:resource]}.#{perm[:action]}"
  Permission.find_or_create_by!(name: name) do |p|
    p.description = perm[:description]
  end
end

puts "  - Created/verified #{system_cve_permissions.size} permissions"

# Assign to admin role (every action)
admin_role = Role.find_by(name: "admin")
if admin_role
  system_cve_permissions.each do |perm|
    name = "#{perm[:resource]}.#{perm[:action]}"
    permission = Permission.find_by(name: name)
    next unless permission

    admin_role.permissions << permission unless admin_role.permissions.include?(permission)
  end
  puts "  - Assigned system.cve.* permissions to admin role"
end

# Manager role: read + manage (security triage is a manager-level concern)
manager_role = Role.find_by(name: "manager")
if manager_role
  manager_actions = %w[read manage]
  manager_permission_names = system_cve_permissions
    .select { |p| manager_actions.include?(p[:action]) }
    .map { |p| "#{p[:resource]}.#{p[:action]}" }
  manager_permission_names.each do |name|
    permission = Permission.find_by(name: name)
    next unless permission

    manager_role.permissions << permission unless manager_role.permissions.include?(permission)
  end
  puts "  - Assigned system.cve.* read/manage permissions to manager role"
end

# Member role: read only
member_role = Role.find_by(name: "member")
if member_role
  read_names = system_cve_permissions
    .select { |p| p[:action] == "read" }
    .map { |p| "#{p[:resource]}.#{p[:action]}" }
  read_names.each do |name|
    permission = Permission.find_by(name: name)
    next unless permission

    member_role.permissions << permission unless member_role.permissions.include?(permission)
  end
  puts "  - Assigned system.cve.* read permissions to member role"
end

puts "System CVE permissions seeding complete."
