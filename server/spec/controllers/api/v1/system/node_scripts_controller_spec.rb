# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — operator CRUD controller spec for node_scripts.
# Permission family: system.scripts.*.
RSpec.describe "Api::V1::System::NodeScripts", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.scripts.read",   account: account) }
  let(:create_user) { user_with_permissions("system.scripts.create", account: account) }
  let(:update_user) { user_with_permissions("system.scripts.update", account: account) }
  let(:delete_user) { user_with_permissions("system.scripts.delete", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let!(:script) { create(:system_node_script, account: account) }

  describe "GET /api/v1/system/node_scripts" do
    it "returns 401 without auth" do
      get "/api/v1/system/node_scripts"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/node_scripts", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "scopes to the caller's account" do
      foreign = create(:system_node_script, account: other_account)
      get "/api/v1/system/node_scripts", headers: auth_headers_for(read_user)
      ids = json_response_data["node_scripts"].map { |s| s["id"] }
      expect(ids).to include(script.id)
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/node_scripts/:id" do
    it "returns 404 for another account's script" do
      foreign = create(:system_node_script, account: other_account)
      get "/api/v1/system/node_scripts/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end

    it "returns the script" do
      get "/api/v1/system/node_scripts/#{script.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["node_script"]["id"]).to eq(script.id)
    end
  end

  describe "POST /api/v1/system/node_scripts" do
    let(:create_params) do
      { node_script: { name: "spec-script-#{SecureRandom.hex(3)}", variety: "custom", data: "#!/bin/sh\nexit 0" } }
    end

    it "returns 403 without create perm" do
      post "/api/v1/system/node_scripts", params: create_params.to_json,
                                          headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a script scoped to the caller's account" do
      expect {
        post "/api/v1/system/node_scripts", params: create_params.to_json,
                                            headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::System::NodeScript.where(account: account).count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "returns 422 on missing name" do
      post "/api/v1/system/node_scripts",
           params: { node_script: { variety: "custom", data: "x" } }.to_json,
           headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/system/node_scripts/:id" do
    it "updates the script" do
      patch "/api/v1/system/node_scripts/#{script.id}",
            params: { node_script: { description: "spec-updated" } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(script.reload.description).to eq("spec-updated")
    end
  end

  describe "DELETE /api/v1/system/node_scripts/:id" do
    it "deletes the script" do
      expect {
        delete "/api/v1/system/node_scripts/#{script.id}", headers: auth_headers_for(delete_user)
      }.to change { ::System::NodeScript.where(account: account).count }.by(-1)
      expect(response).to have_http_status(:ok)
    end
  end
end
