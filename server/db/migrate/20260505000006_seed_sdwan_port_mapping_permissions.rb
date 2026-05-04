# frozen_string_literal: true

# Slice 7b — port mapping permissions. Read for the dashboard tab;
# manage for create/update/delete.
class SeedSdwanPortMappingPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = [
    { name: "sdwan.port_mappings.read",   category: "resource", action: "read",   resource: "port_mappings",
      description: "View SDWAN port mappings (hub DNAT rules) and their compiled nft output" },
    { name: "sdwan.port_mappings.manage", category: "resource", action: "manage", resource: "port_mappings",
      description: "Create, update, and delete SDWAN port mappings" }
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
