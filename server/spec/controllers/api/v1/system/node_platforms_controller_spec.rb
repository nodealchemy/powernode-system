# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for node_platforms.
#
# Permission family: system.platforms.* plus the ultra-sensitive
# system.platforms.manage_disk_image_policy (controls cosign trust regexps
# — without it, those fields silently strip from PATCH payloads). The
# disk_image action returns a signed download URL; tests assert the
# 404-without-image branch since the happy path needs a real FileObject.
RSpec.describe "Api::V1::System::NodePlatforms", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.platforms.read",   account: account) }
  let(:create_user) { user_with_permissions("system.platforms.create", account: account) }
  let(:update_user) { user_with_permissions("system.platforms.update", account: account) }
  let(:delete_user) { user_with_permissions("system.platforms.delete", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:architecture) { create(:system_node_architecture) }
  let!(:platform) { create(:system_node_platform, account: account, node_architecture: architecture) }

  describe "GET /api/v1/system/node_platforms" do
    it "returns 401 without auth" do
      get "/api/v1/system/node_platforms"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/node_platforms", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "scopes to the caller's account" do
      foreign = create(:system_node_platform, account: other_account, node_architecture: architecture)
      get "/api/v1/system/node_platforms", headers: auth_headers_for(read_user)
      ids = json_response_data["node_platforms"].map { |p| p["id"] }
      expect(ids).to include(platform.id)
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/node_platforms/:id" do
    it "returns the platform" do
      get "/api/v1/system/node_platforms/#{platform.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["node_platform"]["id"]).to eq(platform.id)
    end

    it "returns 404 for another account's platform" do
      foreign = create(:system_node_platform, account: other_account, node_architecture: architecture)
      get "/api/v1/system/node_platforms/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/node_platforms" do
    let(:create_params) do
      { node_platform: { name: "spec-platform-#{SecureRandom.hex(3)}",
                          node_architecture_id: architecture.id } }
    end

    it "returns 403 without create perm" do
      post "/api/v1/system/node_platforms", params: create_params.to_json,
                                            headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a platform scoped to the caller's account" do
      expect {
        post "/api/v1/system/node_platforms", params: create_params.to_json,
                                              headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::System::NodePlatform.where(account: account).count }.by(1)
      expect(response).to have_http_status(:created)
    end
  end

  describe "PATCH /api/v1/system/node_platforms/:id" do
    it "updates the platform" do
      patch "/api/v1/system/node_platforms/#{platform.id}",
            params: { node_platform: { description: "spec-updated" } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(platform.reload.description).to eq("spec-updated")
    end

    it "silently strips disk_image_policy fields when caller lacks the manage perm" do
      patch "/api/v1/system/node_platforms/#{platform.id}",
            params: { node_platform: { description: "spec-ok",
                                        cosign_identity_regexp: "EVIL.*" } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(platform.reload.description).to eq("spec-ok")
      # cosign_identity_regexp should NOT have changed because update_user
      # lacks system.platforms.manage_disk_image_policy.
      expect(platform.reload.cosign_identity_regexp).not_to eq("EVIL.*")
    end
  end

  describe "DELETE /api/v1/system/node_platforms/:id" do
    it "deletes the platform" do
      delete "/api/v1/system/node_platforms/#{platform.id}", headers: auth_headers_for(delete_user)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/system/node_platforms/:id/disk_image" do
    it "returns 404 when no disk image has been built yet" do
      get "/api/v1/system/node_platforms/#{platform.id}/disk_image",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end
end
