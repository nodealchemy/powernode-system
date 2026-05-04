# frozen_string_literal: true

# Slice 9a of the SDWAN plan — routing-layer permissions.
#
# Read covers the routing dashboard + sessions + learned routes + topology
# views. Manage covers all mutating actions (lan_subnets edit, network mode
# flip, route policy CRUD, AS number set, RR promotion).
class SeedSdwanRoutingPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = [
    { name: "sdwan.routing.read",    category: "resource", action: "read",   resource: "routing",
      description: "View SDWAN routing state (BGP sessions, learned routes, advertisements, route policies)" },
    { name: "sdwan.routing.manage",  category: "resource", action: "manage", resource: "routing",
      description: "Mutate SDWAN routing state (lan_subnets, routing_protocol, route policies, RR topology, AS number)" }
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
