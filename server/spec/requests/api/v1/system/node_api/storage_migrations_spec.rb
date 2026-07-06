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
#                              coordination fields; (increment 9)
#                              surfaces a terminal migration once
#                              revert/cleanup has been requested
#   POST   /:id/progress     — accepts valid transitions, rejects
#                              illegal ones with 422
#   POST   /:id/fail         — marks failed + appends audit entry
#   POST   /:id/revert_complete  — (increment 9) agent reports the
#                              mount is back on source
#   POST   /:id/cleanup_complete — (increment 9) agent reports the
#                              target-side scratch artifacts are gone
RSpec.describe "Api::V1::System::NodeApi::StorageMigrations", type: :request do
  let(:account)       { create(:account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:node_template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance,
      serial:         SecureRandom.hex(16),
      subject:        "CN=#{instance.id}",
      not_before:     1.hour.ago,
      not_after:      90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
  end

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

      expect(response).to have_http_status(:unprocessable_content)
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

  # Increment 9 (campaign 019f3458) — revert_binding! (R) / cleanup (C).
  describe "GET /index — pending revert/cleanup intent on terminal migrations" do
    it "surfaces a terminal migration once revert has been requested, alongside revert_requested/cleanup_requested flags" do
      failed = ::System::StorageMigration.create!(migration_attrs.merge(status: "failed", failed_at: Time.current))
      failed.revert_binding!(reason: "diverged mount")
      plain_failed = ::System::StorageMigration.create!(migration_attrs.merge(status: "failed", failed_at: Time.current))

      get "/api/v1/system/node_api/storage_migrations", headers: headers
      payload = JSON.parse(response.body).dig("data", "storage_migrations")
      ids = payload.map { |m| m["id"] }

      expect(ids).to include(failed.id)
      expect(ids).not_to include(plain_failed.id) # still excluded — no pending intent
      surfaced = payload.find { |m| m["id"] == failed.id }
      expect(surfaced["revert_requested"]).to be true
      expect(surfaced["cleanup_requested"]).to be false
    end

    it "surfaces a terminal migration once cleanup has been requested, and includes the snapshot_binding" do
      failed = ::System::StorageMigration.create!(
        migration_attrs.merge(status: "failed", failed_at: Time.current, snapshot_subpath: "migrations/2026/test/postgres")
      )
      failed.request_cleanup!(immediate: true)

      get "/api/v1/system/node_api/storage_migrations", headers: headers
      payload = JSON.parse(response.body).dig("data", "storage_migrations").find { |m| m["id"] == failed.id }

      expect(payload["cleanup_requested"]).to be true
      expect(payload["snapshot_binding"]).to include("transport" => "nfs")
    end

    # SAFETY: a blank snapshot_subpath must never yield a mountable
    # binding — mounting with no subpath mounts the NFS export ROOT,
    # and cleanup's `find -delete` would then reach every other
    # deployment's data on shared NFS. snapshot_subpath predates this
    # increment and the column is nullable, so this is reachable in
    # practice (an old migration row, or one created outside the
    # standard system_migrate_storage_component path).
    it "never emits a snapshot_binding when snapshot_subpath is blank" do
      failed = ::System::StorageMigration.create!(
        migration_attrs.merge(status: "failed", failed_at: Time.current, snapshot_subpath: nil)
      )
      failed.request_cleanup!(immediate: true)

      get "/api/v1/system/node_api/storage_migrations", headers: headers
      payload = JSON.parse(response.body).dig("data", "storage_migrations").find { |m| m["id"] == failed.id }

      expect(payload["snapshot_binding"]).to be_nil
    end
  end

  describe "POST /:id/revert_complete" do
    it "marks the revert completed and records one audit entry per artifact" do
      m = ::System::StorageMigration.create!(migration_attrs.merge(status: "failed", failed_at: Time.current))
      m.revert_binding!(reason: "diverged mount")

      post "/api/v1/system/node_api/storage_migrations/#{m.id}/revert_complete",
           params: { status: "completed", artifacts: [ { path: "a:/x/deployments/test/postgres", mount_point: "/var/lib/postgresql" } ] },
           headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      m.reload
      expect(m.metadata["revert_status"]).to eq("completed")
      expect(m.audit_log.last["message"]).to include("a:/x/deployments/test/postgres")
    end

    it "marks the revert failed when the agent reports status: failed" do
      m = ::System::StorageMigration.create!(migration_attrs.merge(status: "failed", failed_at: Time.current))
      m.revert_binding!(reason: "diverged mount")

      post "/api/v1/system/node_api/storage_migrations/#{m.id}/revert_complete",
           params: { status: "failed", reason: "mount source unreachable" },
           headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(m.reload.metadata["revert_status"]).to eq("failed")
    end
  end

  describe "POST /:id/cleanup_complete" do
    it "marks the cleanup completed and records one audit entry per artifact" do
      m = ::System::StorageMigration.create!(migration_attrs.merge(status: "failed", failed_at: Time.current))
      m.request_cleanup!(immediate: true)

      post "/api/v1/system/node_api/storage_migrations/#{m.id}/cleanup_complete",
           params: {
             status: "completed",
             artifacts: [
               { label: "target_subpath", path: "b:/y/deployments/test/postgres", already_clean: false },
               { label: "snapshot_subpath", path: "", already_clean: true }
             ]
           },
           headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      m.reload
      expect(m.metadata["cleanup_status"]).to eq("completed")
      expect(m.metadata["cleaned_at"]).to be_present
      messages = m.audit_log.last(2).map { |e| e["message"] }
      expect(messages).to include(a_string_matching("b:/y/deployments/test/postgres"))
      expect(messages).to include(a_string_matching(/already clean/))
    end
  end
end
