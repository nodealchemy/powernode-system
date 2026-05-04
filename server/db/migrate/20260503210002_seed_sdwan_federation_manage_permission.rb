# frozen_string_literal: true

# Slice 1 seeded sdwan.federation.read; slice 6 adds sdwan.federation.manage
# for proposing + revoking federation peers. Operators with read alone can
# inspect federation state via the index/show endpoints; manage is required
# to mutate.
#
# Slice 6 of the SDWAN plan.
class SeedSdwanFederationManagePermission < ActiveRecord::Migration[8.1]
  PERMISSION = {
    name: "sdwan.federation.manage",
    category: "resource",
    action: "manage",
    resource: "federation",
    description: "Propose and revoke SDWAN federation peers"
  }.freeze

  def up
    return unless defined?(::Permission)

    ::Permission.find_or_create_by!(name: PERMISSION[:name]) do |p|
      p.category    = PERMISSION[:category]    if p.respond_to?(:category=)
      p.action      = PERMISSION[:action]      if p.respond_to?(:action=)
      p.resource    = PERMISSION[:resource]    if p.respond_to?(:resource=)
      p.description = PERMISSION[:description] if p.respond_to?(:description=)
    end
  end

  def down
    return unless defined?(::Permission)

    ::Permission.where(name: PERMISSION[:name]).delete_all
  end
end
