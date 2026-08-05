# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for disk_image_publications.
#
# Nested under node_platforms:
#   GET  /api/v1/system/node_platforms/:platform_id/disk_image_publications
#   GET  /api/v1/system/node_platforms/:platform_id/disk_image_publications/:id
#   POST /api/v1/system/node_platforms/:id/rollback_disk_image
#
# Permissions: system.platforms.read for index/show; rollback uses its own
# system.platforms.rollback_disk_image and gates through Ai::AutonomyGate.
RSpec.describe "Api::V1::System::DiskImagePublications", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)     { user_with_permissions("system.platforms.read",                  account: account) }
  let(:rollback_user) { user_with_permissions("system.platforms.rollback_disk_image",   account: account) }
  let(:no_perms)      { user_with_permissions(account: account) }

  let(:architecture) { create(:system_node_architecture) }
  let!(:platform) { create(:system_node_platform, account: account, node_architecture: architecture) }

  describe "GET /api/v1/system/node_platforms/:platform_id/disk_image_publications" do
    it "returns 401 without auth" do
      get "/api/v1/system/node_platforms/#{platform.id}/disk_image_publications"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/node_platforms/#{platform.id}/disk_image_publications",
          headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the publication history (empty when no publications)" do
      get "/api/v1/system/node_platforms/#{platform.id}/disk_image_publications",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["disk_image_publications"]).to eq([])
    end

    it "returns 404 when the platform belongs to another account" do
      foreign = create(:system_node_platform, account: other_account, node_architecture: architecture)
      get "/api/v1/system/node_platforms/#{foreign.id}/disk_image_publications",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/node_platforms/:id/rollback_disk_image" do
    it "returns 403 without the rollback permission" do
      post "/api/v1/system/node_platforms/#{platform.id}/rollback_disk_image",
           params: { publication_id: SecureRandom.uuid }.to_json,
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 when target publication doesn't exist" do
      post "/api/v1/system/node_platforms/#{platform.id}/rollback_disk_image",
           params: { publication_id: SecureRandom.uuid }.to_json,
           headers: auth_headers_for(rollback_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:not_found)
    end

    # IMP-a1397e4b09b8 — the controller's rollback transaction duplicates
    # System::Executors::DiskImage::RollbackPublication but never calls
    # target.reactivate, so a retired publication rolled back through this
    # REST endpoint stays status: "retired" instead of flipping to
    # "published" (RollbackPublication's own transaction does call
    # reactivate — see rollback_publication.rb:25). The seeded default
    # policy for this action is "require_approval" (deferred to an
    # ApprovalRequest, never reaching the :proceed branch below), so an
    # auto_approve override is required to exercise the buggy path — the
    # same override an autonomous/self-hosted operator would configure.
    it "transitions the target publication from retired to published" do
      Ai::InterventionPolicy.create!(
        account: account, scope: "global",
        action_category: "system.disk_image_publication_rollback",
        policy: "auto_approve", is_active: true, priority: 10
      )
      file_object = create(:file_object, account: account, deleted_at: 2.days.ago,
                                          deleted_by: create(:user))
      # published_at is required here (IMP-c3f186e56d5b): promotable? now
      # requires it as one of three independent conditions, closing a gap
      # where a row could reach :retired without ever having been through a
      # real publish. This fixture builds the row directly off the AASM
      # graph (same as that gap), so it must supply published_at itself to
      # keep modeling a legitimately-published-then-retired row rather than
      # the laundered shape the fix targets.
      target = System::DiskImagePublication.create!(
        account: account, node_platform: platform, file_object: file_object,
        git_sha: SecureRandom.hex(20), sha256: SecureRandom.hex(32),
        size_bytes: 1024, oci_ref: "registry.test/foo:bar",
        arch: "arm64", status: "retired", published_at: 2.days.ago, retired_at: 1.day.ago
      )

      post "/api/v1/system/node_platforms/#{platform.id}/rollback_disk_image",
           params: { publication_id: target.id }.to_json,
           headers: auth_headers_for(rollback_user).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(target.reload.status).to eq("published")
      expect(target.file_object.reload.deleted_at).to be_nil
      expect(target).to be_active
    end
  end
end
