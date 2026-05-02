# frozen_string_literal: true

# Seeds permissions used by the FleetAutonomyService reconcile loop:
#   - system.fleet.reconcile  — granted to system workers that drive the
#     SystemFleetReconcileJob
#   - system.fleet.autonomy   — granted to operator roles for visibility into
#     autonomy decisions and policy editing
#
# Idempotent. Re-running is safe — find_or_create_by guards against duplicates.
class SeedFleetAutonomyPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = {
    "system.fleet.reconcile" => {
      resource: "system.fleet", action: "reconcile",
      description: "Trigger FleetAutonomyService reconcile tick (worker-side)"
    },
    "system.fleet.autonomy" => {
      resource: "system.fleet", action: "autonomy",
      description: "View and edit fleet autonomy policies + approval queue"
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
  end

  def down
    return unless table_exists?(:permissions)

    ::Permission.where(name: PERMISSIONS.keys).destroy_all
  end
end
