# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260925060000_delete_orphaned_platform_health_read_grants.rb"
)

# fc-47 deleted GET /system/platform/health, the one endpoint that checked
# system.platform.health.read, and the permission definition with it. Role
# grants of it already in role_permissions name a permission that no longer
# exists; RolePermission's own validation refuses to create them, so the
# fixtures insert them with raw SQL, as a pre-removal deployment has them.
RSpec.describe DeleteOrphanedPlatformHealthReadGrants do
  subject(:migration) { described_class.new }

  let(:role) { create(:role) }
  let(:connection) { ActiveRecord::Base.connection }

  def grant(permission_name)
    connection.execute(<<~SQL)
      INSERT INTO role_permissions (role_id, permission_name)
      VALUES (#{connection.quote(role.id)}, #{connection.quote(permission_name)})
    SQL
  end

  def granted_names
    connection.select_values(
      "SELECT permission_name FROM role_permissions WHERE role_id = #{connection.quote(role.id)} ORDER BY permission_name"
    )
  end

  before do
    grant("system.platform.health.read")
    grant("system.platform.read")
    grant("system.platform.health.readX")
  end

  it "is no longer a defined permission" do
    expect(Permissions.all_permissions.keys.map(&:to_s)).not_to include("system.platform.health.read")
  end

  describe "#up" do
    it "deletes only the orphaned grant, by exact name" do
      migration.up

      expect(granted_names).to eq(%w[system.platform.health.readX system.platform.read])
    end

    it "is idempotent" do
      migration.up

      expect { migration.up }.not_to raise_error
      expect(granted_names).to eq(%w[system.platform.health.readX system.platform.read])
    end

    it "reports the count and never a role id" do
      logged = []
      allow(migration).to receive(:say) { |message, *| logged << message }

      migration.up

      expect(logged.join("\n")).to include("1")
      expect(logged.join("\n")).not_to include(role.id)
    end
  end

  describe "#down" do
    it "is irreversible" do
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    end
  end
end
