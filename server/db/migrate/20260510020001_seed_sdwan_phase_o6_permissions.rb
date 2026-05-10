# frozen_string_literal: true

# Phase O6 permission seeds — adds the read/manage permission keys
# referenced by the new MCP tool actions for HostBridge / OVN / IPFIX.
# Without these rows, only admin/system callers (which bypass the
# permission check) can invoke the new tools; with them, operators
# granted the appropriate permission can compose dual-profile networks.
#
# Loaded as a migration (not a Rails seed) so fresh checkouts and CI
# databases get them without a separate seed step, matching the
# convention used by 20260503120005_seed_sdwan_permissions.
#
# Phase O6 of the OVS+OVN dual-profile networking roadmap.
class SeedSdwanPhaseO6Permissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = [
    { name: "sdwan.host_bridges.read",   category: "resource", action: "read",   resource: "host_bridges",
      description: "View per-host SDWAN bridges (Linux + OVS)" },
    { name: "sdwan.host_bridges.manage", category: "resource", action: "manage", resource: "host_bridges",
      description: "Allocate and release per-host SDWAN bridges" },
    { name: "sdwan.ovn.read",            category: "resource", action: "read",   resource: "ovn",
      description: "View OVN deployments, logical switches, ports, and compiled plans" },
    { name: "sdwan.ovn.manage",          category: "resource", action: "manage", resource: "ovn",
      description: "Create OVN deployments, logical switches, and ports (heavyweight profile)" },
    { name: "sdwan.ipfix.read",          category: "resource", action: "read",   resource: "ipfix",
      description: "View IPFIX collectors configured for per-flow telemetry" },
    { name: "sdwan.ipfix.manage",        category: "resource", action: "manage", resource: "ipfix",
      description: "Create, update, enable, and disable IPFIX collectors" }
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
