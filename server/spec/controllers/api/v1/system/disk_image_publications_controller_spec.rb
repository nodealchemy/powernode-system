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
  end
end
