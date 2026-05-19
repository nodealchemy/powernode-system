# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — operator CRUD controller spec for
# node_module_categories. Permission family: system.modules.*. Categories
# guard delete when modules reference them — that's the most important
# regression to lock in.
RSpec.describe "Api::V1::System::NodeModuleCategories", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.modules.read",   account: account) }
  let(:create_user) { user_with_permissions("system.modules.create", account: account) }
  let(:update_user) { user_with_permissions("system.modules.update", account: account) }
  let(:delete_user) { user_with_permissions("system.modules.delete", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let!(:category) { create(:system_node_module_category, account: account) }

  describe "GET /api/v1/system/node_module_categories" do
    it "returns 401 without auth" do
      get "/api/v1/system/node_module_categories"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/node_module_categories", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "scopes to the caller's account" do
      foreign = create(:system_node_module_category, account: other_account)
      get "/api/v1/system/node_module_categories", headers: auth_headers_for(read_user)
      ids = json_response_data["node_module_categories"].map { |c| c["id"] }
      expect(ids).to include(category.id)
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/node_module_categories/:id" do
    it "returns 404 for another account's category" do
      foreign = create(:system_node_module_category, account: other_account)
      get "/api/v1/system/node_module_categories/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end

    it "returns the category" do
      get "/api/v1/system/node_module_categories/#{category.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["category"]["id"]).to eq(category.id)
    end
  end

  describe "POST /api/v1/system/node_module_categories" do
    let(:create_params) { { category: { name: "Spec Category #{SecureRandom.hex(3)}" } } }

    it "returns 403 without create perm" do
      post "/api/v1/system/node_module_categories", params: create_params.to_json,
                                                    headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a category" do
      expect {
        post "/api/v1/system/node_module_categories", params: create_params.to_json,
                                                      headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::System::NodeModuleCategory.where(account: account).count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "returns 422 on missing name (category present but empty fields)" do
      post "/api/v1/system/node_module_categories",
           params: { category: { description: "no name" } }.to_json,
           headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/system/node_module_categories/:id" do
    it "updates the category" do
      patch "/api/v1/system/node_module_categories/#{category.id}",
            params: { category: { description: "spec-updated" } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(category.reload.description).to eq("spec-updated")
    end
  end

  describe "DELETE /api/v1/system/node_module_categories/:id" do
    it "deletes an empty category" do
      expect {
        delete "/api/v1/system/node_module_categories/#{category.id}", headers: auth_headers_for(delete_user)
      }.to change { ::System::NodeModuleCategory.where(account: account).count }.by(-1)
      expect(response).to have_http_status(:ok)
    end

    it "returns 422 when modules reference the category (guard against orphans)" do
      platform = create(:system_node_platform, account: account)
      create(:system_node_module, account: account, node_platform: platform, category: category)
      expect {
        delete "/api/v1/system/node_module_categories/#{category.id}", headers: auth_headers_for(delete_user)
      }.not_to change { ::System::NodeModuleCategory.count }
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end
end
