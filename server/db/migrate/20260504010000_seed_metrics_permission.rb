# frozen_string_literal: true

# Seeds the operator-facing permission for the Phase 10.5 metrics endpoint:
#   - system.metrics.read  — read aggregated dispatch + fleet event counters
#
# Idempotent. Re-running is safe — find_or_create_by guards against duplicates.
#
# Reference: comprehensive stabilization sweep Phase 10.5.
class SeedMetricsPermission < ActiveRecord::Migration[8.1]
  PERMISSIONS = {
    "system.metrics.read" => {
      resource: "system.metrics", action: "read",
      description: "Read aggregated dispatch + fleet event counters for the operator dashboard"
    }
  }.freeze

  def up
    return unless table_exists?(:permissions)

    PERMISSIONS.each do |name, attrs|
      ::Permission.find_or_create_by!(name: name) do |p|
        p.resource    = attrs[:resource]
        p.action      = attrs[:action]
        p.description = attrs[:description]
        p.category    = "resource" if p.respond_to?(:category=)
      end
    end

    return unless table_exists?(:roles) && table_exists?(:role_permissions)

    PERMISSIONS.each do |name, _attrs|
      perm = ::Permission.find_by(name: name)
      next unless perm

      # Grant to the standard system operator roles.
      [ "admin", "system_admin", "system_operator" ].each do |role_name|
        ::Role.where(name: role_name).find_each do |role|
          role.permissions << perm unless role.permissions.exists?(id: perm.id)
        end
      end
    end
  end

  def down
    return unless table_exists?(:permissions)

    ::Permission.where(name: PERMISSIONS.keys).destroy_all
  end
end
