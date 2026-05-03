# frozen_string_literal: true

require "rails_helper"

# Anonymous device-side endpoint — physical devices flashed from a
# generic disk image poll here while waiting for an operator to bind
# them to a NodeInstance via the Unclaimed Devices UI.
#
# Per the platform's webhook receiver discipline: never 500. The agent
# polls forever; a 500 storm is worse than a single dropped poll.
RSpec.describe "POST /api/v1/system/node_api/claim", type: :request do
  let!(:account)  { create(:account, name: "Powernode") }
  let(:platform_url) { "http://localhost:3000" }

  describe "first poll" do
    it "creates an UnclaimedDevice and returns pending + claim_code" do
      expect {
        post "/api/v1/system/node_api/claim",
             params: { mac: "AA:BB:CC:DD:EE:01", hostname: "rpi-test", architecture: "arm64", platform_hint: "rpi4" }.to_json,
             headers: { "Content-Type" => "application/json" }
      }.to change { System::UnclaimedDevice.count }.by(1)

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["status"]).to eq("pending")
      expect(data["claim_code"]).to be_present
      expect(data["claim_code"].length).to eq(System::UnclaimedDevice::CLAIM_CODE_LENGTH)
      expect(data["poll_after_seconds"]).to eq(30)
      expect(data["bootstrap_token"]).to be_nil
    end
  end

  describe "subsequent polls" do
    it "returns the same claim_code (idempotent)" do
      post "/api/v1/system/node_api/claim",
           params: { mac: "AA:BB:CC:DD:EE:02" }.to_json,
           headers: { "Content-Type" => "application/json" }
      first_code = JSON.parse(response.body).dig("data", "claim_code")

      post "/api/v1/system/node_api/claim",
           params: { mac: "AA:BB:CC:DD:EE:02" }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(JSON.parse(response.body).dig("data", "claim_code")).to eq(first_code)
    end
  end

  describe "after operator confirms claim" do
    let(:platform) { create(:system_node_platform, account: account) }
    let(:node)     { create(:system_node, account: account) }
    let(:instance) do
      create(:system_node_instance, node: node, variety: "physical", status: "pending")
    end

    it "returns claimed + bootstrap_token + instance_uuid" do
      # Initial poll — controller normalizes MAC to lowercase
      post "/api/v1/system/node_api/claim",
           params: { mac: "AA:BB:CC:DD:EE:03" }.to_json,
           headers: { "Content-Type" => "application/json" }
      unclaimed = System::UnclaimedDevice.find_by!(discovered_mac: "aa:bb:cc:dd:ee:03")

      # Operator confirms (simulating what the operator UI does)
      System::PhysicalEnrollmentService.confirm_claim!(
        unclaimed: unclaimed, node_instance: instance
      )

      # Next device poll → receives bootstrap_token
      post "/api/v1/system/node_api/claim",
           params: { mac: "AA:BB:CC:DD:EE:03" }.to_json,
           headers: { "Content-Type" => "application/json" }
      data = JSON.parse(response.body)["data"]
      expect(data["status"]).to eq("claimed")
      expect(data["bootstrap_token"]).to be_present
      expect(data["instance_uuid"]).to eq(instance.id)
    end
  end

  describe "rejection paths (always 200, never 500)" do
    it "400 when mac is missing" do
      post "/api/v1/system/node_api/claim",
           params: {}.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:bad_request)
    end

    it "200 with status=error when service raises" do
      allow(System::PhysicalEnrollmentService).to receive(:record_discovery!)
        .and_raise(StandardError, "boom")
      post "/api/v1/system/node_api/claim",
           params: { mac: "AA:BB:CC:DD:EE:99" }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "status")).to eq("error")
    end
  end
end
