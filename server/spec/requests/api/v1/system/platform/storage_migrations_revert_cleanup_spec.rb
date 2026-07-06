# frozen_string_literal: true

require "rails_helper"

# Increment 9 (campaign 019f3458) — operator-facing revert/cleanup
# endpoints on Api::V1::System::Platform::StorageMigrationsController.
# These delegate to the MCP actions (system_revert_storage_migration_binding
# / system_cleanup_storage_migration) via call_mcp_action, mirroring how
# #create already delegates to system_migrate_storage_component.
#
# While wiring these up, call_mcp_action turned out to be completely
# broken (PlatformApiToolRegistry.new/.execute don't exist, and
# BaseTool#success_result nests its payload under `data`) — see the
# BUGFIX comment on call_mcp_action itself. #create is the one
# pre-existing action that already went through this helper, so it was
# ALSO silently broken; the "create still works" spec below locks in
# the fix for it. index/show/approve/cancel don't call
# call_mcp_action and had no coverage before this increment either —
# backfilling those is a separate, pre-existing gap out of scope here.
RSpec.describe "Api::V1::System::Platform::StorageMigrations revert/cleanup", type: :request do
  let(:account) { create(:account) }
  let(:scaler)  { user_with_permissions("system.platform.read", "system.platform.scale", account: account) }
  let(:reader_only) { user_with_permissions("system.platform.read", account: account) }

  let(:nfs_volume_type) { create(:system_provider_volume_type, account: account, volume_type: "nfs", name: "nfs-pool") }
  let(:source_volume) do
    create(:system_provider_volume, account: account, volume_type: nfs_volume_type, name: "vol-a",
                                     config: { "nfs" => { "server" => "nas1", "export_path" => "/v1/Powernode" } })
  end
  let(:target_volume) do
    create(:system_provider_volume, account: account, volume_type: nfs_volume_type, name: "vol-b",
                                     config: { "nfs" => { "server" => "nas2", "export_path" => "/v2/Powernode" } })
  end
  let(:instance) { create(:system_node_instance, account: account) }

  let!(:failed_migration) do
    ::System::StorageMigration.create!(
      account: account, node_instance: instance, source_volume: source_volume, target_volume: target_volume,
      role: "postgres", status: "failed", failed_at: Time.current,
      source_subpath: "deployments/test/postgres", target_subpath: "deployments/test/postgres", plan: {}
    )
  end

  describe "POST / (create) — pre-existing action, regression-locks the call_mcp_action bugfix" do
    it "plans a new migration via the MCP action" do
      post "/api/v1/system/platform/storage_migrations",
           headers: auth_headers_for(scaler),
           params: {
             node_instance_id: instance.id, source_volume_id: source_volume.id,
             target_volume_id: target_volume.id, role: "redis"
           }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response_data.dig("storage_migration", "status")).to eq("planned")
    end
  end

  describe "POST /:id/revert" do
    it "requests a revert via the MCP action and returns the updated migration" do
      post "/api/v1/system/platform/storage_migrations/#{failed_migration.id}/revert",
           headers: auth_headers_for(scaler), params: { reason: "diverged mount" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response_data.dig("storage_migration", "metadata", "revert_status")).to eq("requested")
    end

    it "forbids without system.platform.scale" do
      post "/api/v1/system/platform/storage_migrations/#{failed_migration.id}/revert",
           headers: auth_headers_for(reader_only)

      expect(response).to have_http_status(:forbidden)
    end

    it "surfaces the model's reachability error for a non-revertible migration" do
      active = ::System::StorageMigration.create!(
        account: account, node_instance: instance, source_volume: source_volume, target_volume: target_volume,
        role: "postgres", status: "syncing",
        source_subpath: "deployments/test2/postgres", target_subpath: "deployments/test2/postgres", plan: {}
      )

      post "/api/v1/system/platform/storage_migrations/#{active.id}/revert",
           headers: auth_headers_for(scaler), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /:id/cleanup" do
    it "requests cleanup immediately, bypassing the grace window" do
      post "/api/v1/system/platform/storage_migrations/#{failed_migration.id}/cleanup",
           headers: auth_headers_for(scaler), params: { reason: "triaged, safe to clean", immediate: true }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response_data.dig("storage_migration", "metadata", "cleanup_status")).to eq("requested")
    end

    it "refuses within the grace window without immediate: true" do
      post "/api/v1/system/platform/storage_migrations/#{failed_migration.id}/cleanup",
           headers: auth_headers_for(scaler), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body.downcase).to include("grace window")
    end

    it "forbids without system.platform.scale" do
      post "/api/v1/system/platform/storage_migrations/#{failed_migration.id}/cleanup",
           headers: auth_headers_for(reader_only), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
