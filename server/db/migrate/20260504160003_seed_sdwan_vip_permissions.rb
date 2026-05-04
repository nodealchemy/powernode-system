# frozen_string_literal: true

# Slice 9b — VIP permissions. Read for the dashboard + assignment history
# viewer; manage for create/update/delete/failover.
class SeedSdwanVipPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = [
    { name: "sdwan.vips.read",   category: "resource", action: "read",   resource: "vips",
      description: "View SDWAN virtual IPs and their assignment history" },
    { name: "sdwan.vips.manage", category: "resource", action: "manage", resource: "vips",
      description: "Create, update, fail-over, and delete SDWAN virtual IPs" }
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
