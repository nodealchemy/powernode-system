# frozen_string_literal: true

# SDWAN permission seeds. Loaded as a migration (not a Rails seed) so that
# fresh checkouts and CI databases get them without a separate seed step,
# matching the convention used by other System extension permission seeds.
#
# Slice 1 of the SDWAN plan.
class SeedSdwanPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = [
    { name: "sdwan.networks.read",          category: "resource", action: "read",   resource: "networks",
      description: "View SDWAN networks" },
    { name: "sdwan.networks.manage",        category: "resource", action: "manage", resource: "networks",
      description: "Create, update, and delete SDWAN networks" },
    { name: "sdwan.peers.read",             category: "resource", action: "read",   resource: "peers",
      description: "View SDWAN peer membership and status" },
    { name: "sdwan.peers.manage",           category: "resource", action: "manage", resource: "peers",
      description: "Attach and detach SDWAN peers" },
    { name: "sdwan.firewall.read",          category: "resource", action: "read",   resource: "firewall",
      description: "View SDWAN firewall rules" },
    { name: "sdwan.firewall.manage",        category: "resource", action: "manage", resource: "firewall",
      description: "Manage SDWAN firewall rules" },
    { name: "sdwan.user_devices.create_own", category: "resource", action: "create_own", resource: "user_devices",
      description: "Create user VPN devices for own access grants" },
    { name: "sdwan.user_devices.manage",    category: "resource", action: "manage", resource: "user_devices",
      description: "Manage all user VPN devices in the account" },
    { name: "sdwan.federation.read",        category: "resource", action: "read",   resource: "federation",
      description: "View federation peer records" }
  ].freeze

  def up
    return unless defined?(::Permission)

    PERMISSIONS.each do |attrs|
      ::Permission.find_or_create_by!(name: attrs[:name]) do |p|
        p.category    = attrs[:category]    if p.respond_to?(:category=)
        p.action      = attrs[:action]      if p.respond_to?(:action=)
        p.resource    = attrs[:resource]    if p.respond_to?(:resource=)
        p.description = attrs[:description] if p.respond_to?(:description=)
      end
    end
  end

  def down
    return unless defined?(::Permission)

    ::Permission.where(name: PERMISSIONS.map { |p| p[:name] }).delete_all
  end
end
