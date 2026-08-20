# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Sdwan::Networks", type: :request do
  let(:user) { user_with_permissions("system.sdwan.networks.read", "system.sdwan.networks.manage", "system.sdwan.peers.read") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }

  before do
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  describe "GET /api/v1/system/sdwan/networks" do
    it "returns an empty list when no networks exist" do
      get "/api/v1/system/sdwan/networks", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response_data["networks"]).to eq([])
    end

    it "lists networks for the current account only" do
      Sdwan::Network.create!(account_id: account.id, name: "ours")
      other = create(:account)
      Sdwan::Network.create!(account_id: other.id, name: "theirs")

      get "/api/v1/system/sdwan/networks", headers: headers
      expect(response).to have_http_status(:ok)
      names = json_response_data["networks"].map { |n| n["name"] }
      expect(names).to contain_exactly("ours")
    end
  end

  describe "POST /api/v1/system/sdwan/networks" do
    # IMP-051f3811ac60 gated the create; this example is about the WRITE
    # (allocator, defaults, response shape), so it forces the :proceed branch.
    # The gate-routing contract itself lives in networks_create_gating_spec.
    it "creates a network with auto-allocated /64" do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )

      post "/api/v1/system/sdwan/networks",
           params: { network: { name: "edge-overlay", description: "perimeter" } }.to_json,
           headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:created)
      net = json_response_data["network"]
      expect(net["name"]).to eq("edge-overlay")
      expect(net["cidr_64"]).to match(%r{\Afd[0-9a-f:]+::/64\z})
      expect(net["status"]).to eq("registered")
    end

    it "returns 422 with full error messages on duplicate name" do
      Sdwan::Network.create!(account_id: account.id, name: "duplicate")
      post "/api/v1/system/sdwan/networks",
           params: { network: { name: "duplicate" } }.to_json,
           headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
      # render_validation_error places full_messages under details.errors;
      # message line surfaces at top-level "message".
      details = json_response.dig("details", "errors") || []
      expect(details.join(" ") + " " + json_response["message"].to_s)
        .to include("has already been taken")
    end
  end

  describe "GET /api/v1/system/sdwan/networks/:id" do
    it "returns the full network shape" do
      net = Sdwan::Network.create!(account_id: account.id, name: "show-test")
      get "/api/v1/system/sdwan/networks/#{net.id}", headers: headers
      expect(response).to have_http_status(:ok)
      payload = json_response_data["network"]
      expect(payload["id"]).to eq(net.id)
      expect(payload["hub_count"]).to eq(0)
      expect(payload["spoke_count"]).to eq(0)
    end

    it "returns 404 for a network in a different account" do
      other = create(:account)
      net = Sdwan::Network.create!(account_id: other.id, name: "not-yours")
      get "/api/v1/system/sdwan/networks/#{net.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/system/sdwan/networks/:id" do
    # IMP-c159cc6777b1 — gated-CRUD wiring, network resource. UpdateNetwork
    # existed but had no caller: NetworksController#update wrote through
    # @network.update(network_params) behind the permission check alone, so the
    # seeded sdwan.network_update policy matched no gate call — while DELETE
    # below has been gated since the destructive-ops slice. Flipping status /
    # routing_protocol / advertise_overlay_subnet rewrites BGP + AllowedIPs for
    # every peer, so it is at least as consequential as deleting the network.

    let(:reader) { user_with_permissions("system.sdwan.networks.read", account: account) }
    let!(:network) { create(:sdwan_network, account: account, name: "orig", status: "registered") }
    let(:payload) { { network: { status: "suspended" } } }

    def member_path = "/api/v1/system/sdwan/networks/#{network.id}"

    def patch_update(as: user)
      patch member_path, params: payload.to_json,
            headers: auth_headers_for(as).merge("Content-Type" => "application/json")
    end

    # Forces the gate's :proceed branch. A fresh spec account has no
    # InterventionPolicy rows, so InterventionPolicyService falls through to its
    # require_approval default; stub resolve to reach :proceed.
    def auto_approve_policy!
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    it "requires system.sdwan.networks.manage" do
      patch_update(as: reader)

      expect(response).to have_http_status(:forbidden)
    end

    # IMP-1836bb0021b1 — two nits in the hand-inlined validate→gate→execute
    # dance, both fixed once in Ai::GatedActions#gate_update!.
    #
    # (1) THE CARD NAMED THE OLD VALUE. The description interpolated
    # @network.name AFTER the reload that discards the un-gated in-memory
    # change, so a rename asked an approver to authorise "Update SDWAN network
    # 'orig'" with no sign of what it would become — the one fact the approval
    # is actually about.
    it "labels the approval card with the INCOMING name, not the current one" do
      payload.replace({ network: { name: "renamed" } })

      patch_update

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred.description).to include("renamed"),
                                      "the approval card named the pre-change value"
    end

    # (2) FIELD ERRORS WERE LOST ON THE PROCEED PATH. AutonomyGate#evaluate
    # rescues StandardError and returns :blocked with "Gate evaluation failed",
    # so a RecordInvalid raised by the executor — a race, or a DB constraint no
    # model validation mirrors — reached the client as a generic 422 with no
    # details.errors, where the old inline update had returned them.
    it "returns field-level errors when the executor's write is invalid" do
      auto_approve_policy!
      allow(::Sdwan::Executors::UpdateNetwork).to receive(:execute) do
        invalid = ::Sdwan::Network.new
        invalid.errors.add(:name, "has already been taken")
        raise ActiveRecord::RecordInvalid, invalid
      end

      patch_update

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["details"]).to be_present,
                                          "the client lost the field-level errors to a generic gate 422"
      expect(json_response.dig("details", "errors").to_s).to match(/already been taken/)
    end

    # The finding: this wrote the network inline behind the permission check, so
    # sdwan.network_update never resolved against anything.
    it "defers the update through the autonomy gate instead of writing inline" do
      patch_update

      expect(response).to have_http_status(:accepted)
      expect(json_response_data["pending"]).to eq(true)
      expect(network.reload.status).to eq("registered"),
                                       "the network was changed without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "PATCH did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.network_update")
      expect(deferred.executor_class).to eq("Sdwan::Executors::UpdateNetwork")
      expect(deferred.params["network_id"]).to eq(network.id)
      expect(deferred.params.dig("attributes", "status")).to eq("suspended")
    end

    # gate! never calls on_proceed on its :pending branch, so the executor is the
    # only thing that touches the row.
    it "applies the update when the deferred operation is approved" do
      patch_update

      approve_latest_deferred!

      expect(network.reload.status).to eq("suspended"), "approved update left the network unchanged"
    end

    it "updates inline and renders the row when the policy auto-approves" do
      auto_approve_policy!

      patch_update

      expect(response).to have_http_status(:ok)
      expect(json_response_data["network"]["status"]).to eq("suspended")
      expect(network.reload.status).to eq("suspended"), "answered ok over an unchanged network"
      # 200-with-the-row is also what the UNGATED controller answered, so
      # without this the example cannot tell fixed from unfixed.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::UpdateNetwork"),
                                                              "auto-approved update bypassed the gate entirely"
    end

    it "still answers 422 with field errors and opens no gate row for an invalid payload" do
      patch member_path, params: { network: { status: "sideways" } }.to_json,
            headers: headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:unprocessable_content)
      expect(network.reload.status).to eq("registered")
      expect(::Ai::DeferredOperation.count).to eq(0),
                                               "an unsaveable update still opened an autonomy-gate audit row"
    end
  end

  describe "DELETE /api/v1/system/sdwan/networks/:id" do
    # Destructive SDWAN ops route through the autonomy gate. The default
    # intervention policy is require_approval, so the request is accepted (202)
    # and queued as a deferred operation pending approval — the network is not
    # removed until the approval is granted (e.g. via approve_deferred_operation).
    it "gates deletion behind approval as a pending deferred operation" do
      net = Sdwan::Network.create!(account_id: account.id, name: "kill-me")
      delete "/api/v1/system/sdwan/networks/#{net.id}", headers: headers
      expect(response).to have_http_status(:accepted)
      expect(json_response_data["pending"]).to eq(true)
      expect(json_response_data["action_category"]).to eq("sdwan.network_delete")
      expect(json_response_data["deferred_operation_id"]).to be_present
      expect(Sdwan::Network.where(id: net.id).count).to eq(1)
    end
  end
end
