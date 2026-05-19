# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — operator CRUD controller spec for node_mount_points.
# Permission family is dotted: system.storage.mount_points.* (one segment
# deeper than the rest). Destroy guards against in-use mount points (a
# regression here would silently orphan instance_mount_points).
RSpec.describe "Api::V1::System::NodeMountPoints", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.storage.mount_points.read",   account: account) }
  let(:create_user) { user_with_permissions("system.storage.mount_points.create", account: account) }
  let(:update_user) { user_with_permissions("system.storage.mount_points.update", account: account) }
  let(:delete_user) { user_with_permissions("system.storage.mount_points.delete", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let!(:mount_point) { create(:system_node_mount_point, account: account) }

  describe "GET /api/v1/system/node_mount_points" do
    it "returns 401 without auth" do
      get "/api/v1/system/node_mount_points"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/node_mount_points", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "scopes to the caller's account" do
      foreign = create(:system_node_mount_point, account: other_account)
      get "/api/v1/system/node_mount_points", headers: auth_headers_for(read_user)
      ids = json_response_data["mount_points"].map { |m| m["id"] }
      expect(ids).to include(mount_point.id)
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/node_mount_points/:id" do
    it "returns 404 for another account's mount point" do
      foreign = create(:system_node_mount_point, account: other_account)
      get "/api/v1/system/node_mount_points/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end

    it "returns the mount point" do
      get "/api/v1/system/node_mount_points/#{mount_point.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["mount_point"]["id"]).to eq(mount_point.id)
    end
  end

  describe "POST /api/v1/system/node_mount_points" do
    let(:create_params) do
      { mount_point: { name: "spec-mp-#{SecureRandom.hex(3)}",
                        mount_path: "/mnt/spec",
                        mount_type: "tmpfs",
                        source: "tmpfs",
                        options: { size: "32m" } } }
    end

    it "returns 403 without create perm" do
      post "/api/v1/system/node_mount_points", params: create_params.to_json,
                                               headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a mount point" do
      expect {
        post "/api/v1/system/node_mount_points", params: create_params.to_json,
                                                 headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::System::NodeMountPoint.where(account: account).count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "returns 422 on missing name" do
      post "/api/v1/system/node_mount_points",
           params: { mount_point: { mount_path: "/mnt/spec", mount_type: "tmpfs", source: "tmpfs" } }.to_json,
           headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/system/node_mount_points/:id" do
    it "updates the mount point" do
      patch "/api/v1/system/node_mount_points/#{mount_point.id}",
            params: { mount_point: { description: "spec-updated" } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(mount_point.reload.description).to eq("spec-updated")
    end
  end

  describe "DELETE /api/v1/system/node_mount_points/:id" do
    it "deletes the mount point when unused" do
      expect {
        delete "/api/v1/system/node_mount_points/#{mount_point.id}", headers: auth_headers_for(delete_user)
      }.to change { ::System::NodeMountPoint.where(account: account).count }.by(-1)
      expect(response).to have_http_status(:ok)
    end

    it "returns 422 when an InstanceMountPoint still references it" do
      node = create(:system_node, account: account)
      instance = create(:system_node_instance, node: node, account: account)
      create(:system_instance_mount_point, node_instance: instance, mount_point: mount_point)
      delete "/api/v1/system/node_mount_points/#{mount_point.id}", headers: auth_headers_for(delete_user)
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end
end
