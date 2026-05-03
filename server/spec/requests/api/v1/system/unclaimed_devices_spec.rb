# frozen_string_literal: true

require "rails_helper"

# Operator-facing CRUD for the unclaimed-devices queue.
RSpec.describe "Api::V1::System::UnclaimedDevices", type: :request do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) do
    create(:system_node_instance, node: node, variety: "physical", status: "pending")
  end
  let(:operator) do
    user_with_permissions(
      "system.unclaimed_devices.read",
      "system.unclaimed_devices.discard",
      "system.instances.claim",
      account: account
    )
  end
  let(:headers) { auth_headers_for(operator).merge("Content-Type" => "application/json") }
  let!(:device) do
    create(:system_unclaimed_device, account: account, discovered_mac: "aa:bb:cc:dd:ee:01")
  end

  describe "GET /api/v1/system/unclaimed_devices" do
    it "lists active devices for the operator's account" do
      get "/api/v1/system/unclaimed_devices", headers: headers
      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).dig("data", "unclaimed_devices").map { |d| d["id"] }
      expect(ids).to include(device.id)
    end

    it "excludes expired devices" do
      device.update!(expires_at: 1.minute.ago)
      get "/api/v1/system/unclaimed_devices", headers: headers
      ids = JSON.parse(response.body).dig("data", "unclaimed_devices").map { |d| d["id"] }
      expect(ids).not_to include(device.id)
    end
  end

  describe "POST /api/v1/system/unclaimed_devices/:id/claim" do
    it "binds device to instance + returns updated record" do
      post "/api/v1/system/unclaimed_devices/#{device.id}/claim",
           params: { node_instance_id: instance.id }.to_json,
           headers: headers
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["unclaimed_device"]["claimed_at"]).to be_present
      expect(data["node_instance_id"]).to eq(instance.id)

      device.reload
      expect(device.claimed_node_instance_id).to eq(instance.id)
      instance.reload
      expect(instance.claimed?).to be true
    end

    it "400 when node_instance_id missing" do
      post "/api/v1/system/unclaimed_devices/#{device.id}/claim",
           params: {}.to_json, headers: headers
      expect(response).to have_http_status(:bad_request)
    end

    it "404 when target NodeInstance not in operator's account" do
      other_account = create(:account)
      other_node = create(:system_node, account: other_account)
      other_instance = create(:system_node_instance, node: other_node)

      post "/api/v1/system/unclaimed_devices/#{device.id}/claim",
           params: { node_instance_id: other_instance.id }.to_json,
           headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/system/unclaimed_devices/:id" do
    it "destroys the row and returns success" do
      expect {
        delete "/api/v1/system/unclaimed_devices/#{device.id}", headers: headers
      }.to change { System::UnclaimedDevice.count }.by(-1)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "auth" do
    it "rejects when operator lacks system.unclaimed_devices.read" do
      no_perms = user_with_permissions(account: account)
      get "/api/v1/system/unclaimed_devices",
          headers: auth_headers_for(no_perms)
      expect(response.status).to be_in([ 401, 403, 422 ])
    end
  end
end
