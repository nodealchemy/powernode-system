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

  # Regression: the serializer emitted `templates_count` (plural) while the
  # frontend reads `template_count`, and never emitted a module count at all —
  # so the catalog always showed 0/0 despite real associations. The counts are
  # now batched across the page in the controller (grouped queries) and fall
  # back to per-record queries on the single-record show path.
  describe "template_count and module_count" do
    # Two templates sharing one module:
    #   template_a → mod_1, mod_2
    #   template_b → mod_2, mod_3   (mod_2 shared)
    # distinct modules on the platform = {mod_1, mod_2, mod_3} = 3
    let!(:counted_platform) { create(:system_node_platform, account: account, node_architecture: architecture) }
    let(:template_a) { create(:system_node_template, account: account, node_platform: counted_platform) }
    let(:template_b) { create(:system_node_template, account: account, node_platform: counted_platform) }
    let(:mod_1) { create(:system_node_module, account: account, node_platform: counted_platform) }
    let(:mod_2) { create(:system_node_module, account: account, node_platform: counted_platform) }
    let(:mod_3) { create(:system_node_module, account: account, node_platform: counted_platform) }

    before do
      create(:system_template_module, node_template: template_a, node_module: mod_1)
      create(:system_template_module, node_template: template_a, node_module: mod_2)
      create(:system_template_module, node_template: template_b, node_module: mod_2)
      create(:system_template_module, node_template: template_b, node_module: mod_3)
    end

    it "reports batched template_count and DISTINCT module_count in the index" do
      get "/api/v1/system/node_platforms", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      row = json_response_data["node_platforms"].find { |p| p["id"] == counted_platform.id }
      expect(row["template_count"]).to eq(2)
      expect(row["module_count"]).to eq(3)
    end

    it "defaults both counts to 0 for a platform with no templates" do
      get "/api/v1/system/node_platforms", headers: auth_headers_for(read_user)
      row = json_response_data["node_platforms"].find { |p| p["id"] == platform.id }
      expect(row["template_count"]).to eq(0)
      expect(row["module_count"]).to eq(0)
    end

    it "reports the same counts on the single-record show (serializer fallback)" do
      get "/api/v1/system/node_platforms/#{counted_platform.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      body = json_response_data["node_platform"]
      expect(body["template_count"]).to eq(2)
      expect(body["module_count"]).to eq(3)
    end
  end
end
