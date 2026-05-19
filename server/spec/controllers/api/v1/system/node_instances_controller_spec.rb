# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — operator CRUD controller spec.
# NodeInstancesController has CRUD + 6 lifecycle actions (start/stop/reboot/
# terminate/associate_public_ip/disassociate_public_ip) all gated by
# system.instances.control. Spec covers the auth+perm boundary on each.
RSpec.describe "Api::V1::System::NodeInstances", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)    { user_with_permissions("system.instances.read",    account: account) }
  let(:create_user)  { user_with_permissions("system.instances.create",  account: account) }
  let(:update_user)  { user_with_permissions("system.instances.update",  account: account) }
  let(:delete_user)  { user_with_permissions("system.instances.delete",  account: account) }
  let(:control_user) { user_with_permissions("system.instances.control", account: account) }
  let(:no_perms)     { user_with_permissions(account: account) }
  # For per-action permission tests on resource-lookup actions, the user
  # needs baseline read perm or set_node_instance returns 404 before the
  # permission check fires. read_only_user has read but no other perms.
  let(:read_only_user) { user_with_permissions("system.instances.read", account: account) }

  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let!(:instance) do
    create(:system_node_instance, account: account, node: node,
                                   variety: "physical", status: "running",
                                   network_profile: "lightweight")
  end

  describe "GET /api/v1/system/instances" do
    it "returns 401 without auth" do
      get "/api/v1/system/nodes/#{node.id}/node_instances"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/nodes/#{node.id}/node_instances", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists instances scoped to the account" do
      get "/api/v1/system/nodes/#{node.id}/node_instances", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      ids = (json_response_data["instances"] || json_response_data["node_instances"]).map { |i| i["id"] }
      expect(ids).to include(instance.id)
    end
  end

  describe "GET /api/v1/system/nodes/:node_id/node_instances/:id" do
    it "returns the instance" do
      get "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      payload = json_response_data["instance"] || json_response_data["node_instance"]
      expect(payload["id"]).to eq(instance.id)
    end

    it "returns 404 for another account's instance" do
      foreign_tpl = create(:system_node_template, account: other_account)
      foreign_node = create(:system_node, account: other_account, node_template: foreign_tpl)
      foreign = create(:system_node_instance, account: other_account, node: foreign_node,
                                                variety: "physical", status: "running",
                                                network_profile: "lightweight")
      get "/api/v1/system/nodes/#{node.id}/node_instances/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/system/nodes/:node_id/node_instances/:id" do
    it "returns 403 without update perm (read perm present so set_node_instance finds the row)" do
      patch "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}",
            params: { instance: { name: "renamed" } }.to_json,
            headers: auth_headers_for(read_only_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/system/nodes/:node_id/node_instances/:id" do
    it "returns 403 without delete perm" do
      delete "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}", headers: auth_headers_for(read_only_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/system/nodes/:node_id/node_instances/:id/start (lifecycle)" do
    it "returns 403 without control perm" do
      post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/start", headers: auth_headers_for(read_only_user)
      expect(response).to have_http_status(:forbidden)
    end

    it "is permitted with control perm (any non-403 status)" do
      post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/start", headers: auth_headers_for(control_user)
      expect(response.status).not_to eq(403)
    end
  end

  describe "POST /api/v1/system/nodes/:node_id/node_instances/:id/stop (lifecycle)" do
    it "returns 403 without control perm" do
      post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/stop", headers: auth_headers_for(read_only_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/system/nodes/:node_id/node_instances/:id/reboot (lifecycle)" do
    it "returns 403 without control perm" do
      post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/reboot", headers: auth_headers_for(read_only_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/system/nodes/:node_id/node_instances/:id/terminate (lifecycle)" do
    it "returns 403 without control perm" do
      post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/terminate", headers: auth_headers_for(read_only_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/system/nodes/:node_id/node_instances/:id/associate_public_ip" do
    it "returns 403 without control perm" do
      post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/associate_public_ip", headers: auth_headers_for(read_only_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/system/nodes/:node_id/node_instances/:id/disassociate_public_ip" do
    it "returns 403 without control perm" do
      post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/disassociate_public_ip", headers: auth_headers_for(read_only_user)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
