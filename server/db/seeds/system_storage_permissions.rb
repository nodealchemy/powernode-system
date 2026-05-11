# frozen_string_literal: true

# System Storage Assignment permissions — Phase S5.
#
# Distinct from platform's `admin.storage.*` (which governs the
# FileManagement::Storage CRUD page). These permissions gate the
# system-extension's assignment + credential lifecycle endpoints.

puts "Seeding system.storage.* permissions..."

system_storage_permissions = [
  { resource: "system.storage.assignments", action: "read",
    description: "View storage assignments and credentials metadata" },
  { resource: "system.storage.assignments", action: "create",
    description: "Create new storage assignments (bind storage to instances)" },
  { resource: "system.storage.assignments", action: "update",
    description: "Update storage assignments (mount path, options, encryption)" },
  { resource: "system.storage.assignments", action: "delete",
    description: "Remove storage assignments and unmount on nodes" },
  { resource: "system.storage.assignments", action: "assign",
    description: "Bulk-assign storage providers to fleet" },
  { resource: "system.storage.assignments", action: "rotate_credential",
    description: "Rotate per-instance storage credentials" },

  { resource: "system.storage.mount_points", action: "read",
    description: "View synthetic mount points (tmpfs, bind, custom)" },
  { resource: "system.storage.mount_points", action: "create",
    description: "Create synthetic mount points" },
  { resource: "system.storage.mount_points", action: "update",
    description: "Update synthetic mount points" },
  { resource: "system.storage.mount_points", action: "delete",
    description: "Delete synthetic mount points" }
]

system_storage_permissions.each do |perm|
  name = "#{perm[:resource]}.#{perm[:action]}"
  Permission.find_or_create_by!(name: name) do |p|
    p.description = perm[:description]
  end
end

puts "  - Created/verified #{system_storage_permissions.size} permissions"

# Assign to admin role (every action)
admin_role = Role.find_by(name: "admin")
if admin_role
  system_storage_permissions.each do |perm|
    name = "#{perm[:resource]}.#{perm[:action]}"
    permission = Permission.find_by(name: name)
    next unless permission

    admin_role.permissions << permission unless admin_role.permissions.include?(permission)
  end
  puts "  - Assigned system.storage.* permissions to admin role"
end

# Manager role: read + create + update + assign + rotate (not delete)
manager_role = Role.find_by(name: "manager")
if manager_role
  manager_actions = %w[read create update assign rotate_credential]
  manager_permission_names = system_storage_permissions
    .select { |p| manager_actions.include?(p[:action]) }
    .map { |p| "#{p[:resource]}.#{p[:action]}" }
  manager_permission_names.each do |name|
    permission = Permission.find_by(name: name)
    next unless permission

    manager_role.permissions << permission unless manager_role.permissions.include?(permission)
  end
  puts "  - Assigned system.storage.* read/write permissions to manager role"
end

# Member role: read only
member_role = Role.find_by(name: "member")
if member_role
  read_names = system_storage_permissions
    .select { |p| p[:action] == "read" }
    .map { |p| "#{p[:resource]}.#{p[:action]}" }
  read_names.each do |name|
    permission = Permission.find_by(name: name)
    next unless permission

    member_role.permissions << permission unless member_role.permissions.include?(permission)
  end
  puts "  - Assigned system.storage.* read permissions to member role"
end

puts "System Storage permissions seeding complete."
