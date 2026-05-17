# frozen_string_literal: true

require "rails_helper"

# Locks the agent-facing storage-migration contract. The on-node Go
# agent depends on this surface for the cutover sequence; if any of
# the response shapes or transition guards drift, the agent's
# stepCutover regresses silently.
#
# Coverage:
#   GET    /index            — scoped to current instance, filters
#                              terminal status, includes consumer
#                              coordination fields
#   POST   /:id/progress     — accepts valid transitions, rejects
#                              illegal ones with 422
#   POST   /:id/fail         — marks failed + appends audit entry
RSpec.describe "Api::V1::System::NodeApi::StorageMigrations", type: :request do
  let(:account)       { create(:account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:node_template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }

  let(:auth_token) do
    ::Security::JwtService.encode({
      sub:     instance.id,
      type:    "instance",
      version: ::Security::JwtService::CURRENT_TOKEN_VERSION
    })
  end
  let(:headers) { { "X-Instance-Token" => auth_token } }

  let(:nfs_volume_type) do
    create(:system_provider_volume_type, account: account, volume_type: "nfs", name: "nfs-pool")
  end
  let(:source_volume) do
    create(:system_provider_volume, account: account, volume_type: nfs_volume_type, name: "vol-a",
                                     config: { "nfs" => { "server" => "nas1", "export_path" => "/v1/Powernode" } })
  end
  let(:target_volume) do
    create(:system_provider_volume, account: account, volume_type: nfs_volume_type, name: "vol-b",
                                     config: { "nfs" => { "server" => "nas2", "export_path" => "/v2/Powernode" } })
  end

  let(:migration_attrs) do
    {
      account:          account,
      node_instance:    instance,
      source_volume:    source_volume,
      target_volume:    target_volume,
      role:             "postgres",
      status:           "approved",
      source_subpath:   "deployments/test/postgres",
      target_subpath:   "deployments/test/postgres",
      plan:             { "deployment_name" => "test", "role" => "postgres" }
    }
  end

  describe "GET /index" do
    it "returns only non-terminal migrations for this instance" do
      active     = ::System::StorageMigration.create!(migration_attrs)
      completed  = ::System::StorageMigration.create!(migration_attrs.merge(status: "completed", completed_at: Time.current))
      _cancelled = ::System::StorageMigration.create!(migration_attrs.merge(status: "cancelled", cancelled_at: Time.current))

      get "/api/v1/system/node_api/storage_migrations", headers: headers
      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).dig("data", "storage_migrations").map { |m| m["id"] }
      expect(ids).to include(active.id)
      expect(ids).not_to include(completed.id)
    end

    it "does NOT return migrations owned by other instances" do
      other_instance = create(:system_node_instance, node: node, status: "running")
      mine    = ::System::StorageMigration.create!(migration_attrs)
      _theirs = ::System::StorageMigration.create!(migration_attrs.merge(node_instance: other_instance))

      get "/api/v1/system/node_api/storage_migrations", headers: headers
      ids = JSON.parse(response.body).dig("data", "storage_migrations").map { |m| m["id"] }
      expect(ids).to eq([ mine.id ])
    end

    it "surfaces source/target bindings and consumer coordination fields" do
      instance.update!(config: { "storage_volume" => { "mount_point" => "/var/lib/postgresql" } })
      ::System::StorageMigration.create!(migration_attrs)

      get "/api/v1/system/node_api/storage_migrations", headers: headers
      payload = JSON.parse(response.body).dig("data", "storage_migrations").first
      expect(payload["consumer_mount_point"]).to eq("/var/lib/postgresql")
      expect(payload["source_binding"]).to include("transport" => "nfs")
      expect(payload["source_binding"]["nfs"]).to include("server" => "nas1")
      expect(payload["target_binding"]["nfs"]).to include("server" => "nas2")
    end
  end

  describe "POST /:id/progress" do
    it "advances a valid transition and writes audit log" do
      m = ::System::StorageMigration.create!(migration_attrs)

      post "/api/v1/system/node_api/storage_migrations/#{m.id}/progress",
           params: { status: "preparing", note: "agent up" },
           headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      m.reload
      expect(m.status).to eq("preparing")
      # The audit log gets two entries: the transition + the progress
      # note's own append. Look for the transition entry anywhere.
      expect(m.audit_log.any? { |e| e["status_after"] == "preparing" }).to be true
    end

    it "rejects an illegal transition with 422" do
      m = ::System::StorageMigration.create!(migration_attrs)

      post "/api/v1/system/node_api/storage_migrations/#{m.id}/progress",
           params: { status: "completed" },
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(m.reload.status).to eq("approved")
    end

    it "accepts byte-count progress without a status transition" do
      m = ::System::StorageMigration.create!(migration_attrs.merge(status: "syncing"))

      post "/api/v1/system/node_api/storage_migrations/#{m.id}/progress",
           params: { bytes_copied: 12_345, bytes_total: 100_000, note: "halfway" },
           headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      m.reload
      expect(m.status).to eq("syncing")
      expect(m.bytes_copied).to eq(12_345)
    end
  end

  describe "POST /:id/fail" do
    it "marks the migration failed and records the reason" do
      m = ::System::StorageMigration.create!(migration_attrs.merge(status: "syncing"))

      post "/api/v1/system/node_api/storage_migrations/#{m.id}/fail",
           params: { reason: "rsync exited 23" },
           headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      m.reload
      expect(m.status).to eq("failed")
      expect(m.error_message).to eq("rsync exited 23")
    end

    it "returns 404 for a migration belonging to another instance" do
      other_instance = create(:system_node_instance, node: node, status: "running")
      theirs = ::System::StorageMigration.create!(migration_attrs.merge(node_instance: other_instance))

      post "/api/v1/system/node_api/storage_migrations/#{theirs.id}/fail",
           params: { reason: "stolen" },
           headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
