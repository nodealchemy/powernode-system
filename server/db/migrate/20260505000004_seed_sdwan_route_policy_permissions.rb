# frozen_string_literal: true

# Slice 9e — route-policy permissions. read for the policy editor view;
# manage for create/update/delete. Compose with sdwan.routing.* — a user
# who can manage routing can typically manage policies too, but this
# split lets operators give read-only audit access to the policy graph.
class SeedSdwanRoutePolicyPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = [
    { name: "sdwan.route_policies.read",   category: "resource", action: "read",   resource: "route_policies",
      description: "View SDWAN route policies and their compiled FRR route-map output" },
    { name: "sdwan.route_policies.manage", category: "resource", action: "manage", resource: "route_policies",
      description: "Create, update, and delete SDWAN route policies; apply them to networks/peers" }
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
