# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — operator CRUD controller spec.
#
# NodesController is the canonical operator-CRUD shape: index/show/create/
# update/destroy + a custom apply_template action. Per-permission gates on
# every action (system.nodes.read/create/update/delete) + per-account
# scoping enforced via @account.system_nodes scope.
RSpec.describe "Api::V1::System::Nodes", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.nodes.read",   account: account) }
  let(:create_user) { user_with_permissions("system.nodes.create", account: account) }
  let(:update_user) { user_with_permissions("system.nodes.update", account: account) }
  let(:delete_user) { user_with_permissions("system.nodes.delete", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:template) { create(:system_node_template, account: account) }
  let!(:node) { create(:system_node, account: account, node_template: template) }

  describe "GET /api/v1/system/nodes" do
    it "returns 401 without auth" do
      get "/api/v1/system/nodes"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when user lacks system.nodes.read" do
      get "/api/v1/system/nodes", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the caller's account's nodes" do
      get "/api/v1/system/nodes", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      ids = json_response_data["nodes"].map { |n| n["id"] }
      expect(ids).to include(node.id)
    end

    it "scopes to the caller's account (no cross-tenant leakage)" do
      foreign_tpl = create(:system_node_template, account: other_account)
      foreign = create(:system_node, account: other_account, node_template: foreign_tpl)
      get "/api/v1/system/nodes", headers: auth_headers_for(read_user)
      ids = json_response_data["nodes"].map { |n| n["id"] }
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/nodes/:id" do
    it "returns 401 without auth" do
      get "/api/v1/system/nodes/#{node.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/nodes/#{node.id}", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the node" do
      get "/api/v1/system/nodes/#{node.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["node"]["id"]).to eq(node.id)
    end

    it "returns 404 for another account's node (account-scoped lookup)" do
      foreign_tpl = create(:system_node_template, account: other_account)
      foreign = create(:system_node, account: other_account, node_template: foreign_tpl)
      get "/api/v1/system/nodes/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/nodes" do
    let(:create_params) do
      { node: { name: "spec-test-node-#{SecureRandom.hex(3)}",
                node_template_id: template.id } }
    end

    it "returns 401 without auth" do
      post "/api/v1/system/nodes", params: create_params.to_json,
                                    headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without create perm" do
      post "/api/v1/system/nodes", params: create_params.to_json,
                                    headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a node scoped to the caller's account" do
      expect {
        post "/api/v1/system/nodes", params: create_params.to_json,
                                      headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::System::Node.where(account: account).count }.by(1)
      expect(response).to have_http_status(:created)
      expect(::System::Node.find(json_response_data["node"]["id"]).account_id).to eq(account.id)
    end

    it "returns 422 on missing required fields" do
      post "/api/v1/system/nodes", params: { node: { node_template_id: template.id } }.to_json,
                                    headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/system/nodes/:id" do
    let(:update_params) { { node: { name: "renamed-#{SecureRandom.hex(3)}" } } }

    it "returns 403 without update perm" do
      patch "/api/v1/system/nodes/#{node.id}", params: update_params.to_json,
                                                 headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "updates the node" do
      patch "/api/v1/system/nodes/#{node.id}", params: update_params.to_json,
                                                 headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(node.reload.name).to eq(update_params[:node][:name])
    end
  end

  describe "DELETE /api/v1/system/nodes/:id" do
    it "returns 403 without delete perm" do
      delete "/api/v1/system/nodes/#{node.id}", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "deletes the node" do
      expect {
        delete "/api/v1/system/nodes/#{node.id}", headers: auth_headers_for(delete_user)
      }.to change { ::System::Node.where(account: account).count }.by(-1)
      expect(response).to have_http_status(:ok)
    end
  end
end
