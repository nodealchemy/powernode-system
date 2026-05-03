# frozen_string_literal: true

# Seeds permissions for the physical-device claim flow:
#   - system.unclaimed_devices.read    — operator views pending claims
#   - system.unclaimed_devices.discard — operator dismisses stale entries
#   - system.instances.claim           — operator confirms a device-to-instance binding
#
# Idempotent: re-running is safe (find_or_create_by).
class SeedPhysicalEnrollmentPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = {
    "system.unclaimed_devices.read" => {
      resource: "system.unclaimed_devices", action: "read",
      description: "List physical devices polling /claim that haven't been bound to a NodeInstance yet"
    },
    "system.unclaimed_devices.discard" => {
      resource: "system.unclaimed_devices", action: "discard",
      description: "Dismiss a stale unclaimed-device record"
    },
    "system.instances.claim" => {
      resource: "system.instances", action: "claim",
      description: "Confirm a physical device's identity and bind it to a NodeInstance (issues bootstrap token)"
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
