# frozen_string_literal: true

# Seeds the permission used by the SystemCloudSyncJob → worker_api endpoint:
#   - system.cloud_sync.reconcile  — granted to system workers that drive
#     the hourly cloud-state reconciliation tick
#
# Idempotent. Re-running is safe — find_or_create_by guards against duplicates.
#
# Reference: comprehensive stabilization sweep P2.1.
class SeedCloudSyncPermission < ActiveRecord::Migration[8.1]
  PERMISSIONS = {
    "system.cloud_sync.reconcile" => {
      resource: "system.cloud_sync", action: "reconcile",
      description: "Trigger CloudSyncService reconcile tick (worker-side, hourly cron)"
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

    # Grant to any existing "system worker" role.
    return unless table_exists?(:roles) && table_exists?(:role_permissions)

    PERMISSIONS.each do |name, _attrs|
      perm = ::Permission.find_by(name: name)
      next unless perm

      ::Role.where(name: "system_worker").find_each do |role|
        role.permissions << perm unless role.permissions.exists?(id: perm.id)
      end
    end
  end

  def down
    return unless table_exists?(:permissions)

    ::Permission.where(name: PERMISSIONS.keys).destroy_all
  end
end
