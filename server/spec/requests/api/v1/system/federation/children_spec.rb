# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Federation::Children", type: :request do
  let(:account) { create(:account) }
  let(:reader_user) { user_with_permissions("system.children.read", account: account) }
  let(:spawner_user) do
    user_with_permissions("system.children.read", "system.children.spawn", account: account)
  end
  let(:manager_user) do
    user_with_permissions("system.children.read", "system.children.manage", account: account)
  end

  let(:base_path) { "/api/v1/system/federation/children" }

  describe "GET /children" do
    let!(:managed_child) do
      create(:system_federation_peer, :platform, account: account,
              status: "active", spawn_role: "parent", spawn_mode: "managed_child")
    end
    let!(:autonomous_child) do
      create(:system_federation_peer, :platform, account: account,
              status: "active", spawn_role: "parent", spawn_mode: "autonomous_peer")
    end
    # NOT a spawned-child row: peer_kind=platform but spawn_role=symmetric (we joined an existing peer, didn't spawn)
    let!(:symmetric_peer) do
      create(:system_federation_peer, :platform, account: account,
              status: "active", spawn_role: "symmetric")
    end

    it "lists only spawn_role=parent platform peers (children we spawned)" do
      get base_path, headers: auth_headers_for(reader_user)
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      ids = body["data"]["children"].map { |c| c["id"] }
      expect(ids).to match_array([ managed_child.id, autonomous_child.id ])
      expect(ids).not_to include(symmetric_peer.id)
    end

    it "filters by spawn_mode" do
      get base_path, headers: auth_headers_for(reader_user), params: { spawn_mode: "managed_child" }
      ids = JSON.parse(response.body)["data"]["children"].map { |c| c["id"] }
      expect(ids).to eq([ managed_child.id ])
    end

    it "scopes to current account (no cross-tenant leak)" do
      other = create(:account)
      create(:system_federation_peer, :platform, account: other,
              status: "active", spawn_role: "parent", spawn_mode: "managed_child")
      get base_path, headers: auth_headers_for(reader_user)
      body = JSON.parse(response.body)
      expect(body["data"]["children"].size).to eq(2) # only this account's
    end

    it "403 without read permission" do
      get base_path, headers: auth_headers_for(create(:user, account: account))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /children/spawn" do
    let(:base_payload) do
      {
        spawn_mode: "managed_child",
        parent_url: "https://parent.alice.tld",
        spawn_target: { template_id: "powernode-hub", region: "us-west" }
      }
    end

    it "creates a child + returns the acceptance token ONCE" do
      post "#{base_path}/spawn",
           params: base_payload.to_json,
           headers: auth_headers_for(spawner_user).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      data = body["data"]
      expect(data["child"]["spawn_mode"]).to eq("managed_child")
      expect(data["child"]["status"]).to eq("proposed")
      expect(data["acceptance_token"]).to be_present
      expect(data["spawn_payload"]["parent_url"]).to eq("https://parent.alice.tld")
      expect(data["spawn_payload"]["spawn_mode"]).to eq("managed_child")
    end

    it "400 when required fields are missing" do
      post "#{base_path}/spawn",
           params: { spawn_mode: "managed_child" }.to_json,
           headers: auth_headers_for(spawner_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
    end

    it "400 with invalid spawn_mode" do
      post "#{base_path}/spawn",
           params: base_payload.merge(spawn_mode: "fly-me-to-the-moon").to_json,
           headers: auth_headers_for(spawner_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
    end

    it "422 when service returns failure (e.g. invalid spawn_target)" do
      post "#{base_path}/spawn",
           params: base_payload.merge(spawn_target: { region: "us-west" }).to_json, # no template_id
           headers: auth_headers_for(spawner_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "403 without spawn permission" do
      post "#{base_path}/spawn",
           params: base_payload.to_json,
           headers: auth_headers_for(reader_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /children/:id/revoke" do
    let!(:child) do
      create(:system_federation_peer, :platform, account: account,
              status: "active", spawn_role: "parent", spawn_mode: "autonomous_peer")
    end

    it "revokes the child" do
      post "#{base_path}/#{child.id}/revoke",
           params: { reason: "decommission" }.to_json,
           headers: auth_headers_for(manager_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(child.reload.status).to eq("revoked")
      expect(child.metadata["revocation_reason"]).to eq("decommission")
    end

    it "409 when already revoked" do
      child.update_columns(status: "revoked")
      post "#{base_path}/#{child.id}/revoke",
           headers: auth_headers_for(manager_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:conflict)
    end

    it "404 for child in a different account" do
      other_child = create(:system_federation_peer, :platform, account: create(:account),
                            status: "active", spawn_role: "parent", spawn_mode: "autonomous_peer")
      post "#{base_path}/#{other_child.id}/revoke",
           headers: auth_headers_for(manager_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:not_found)
    end

    it "403 without manage permission" do
      post "#{base_path}/#{child.id}/revoke",
           headers: auth_headers_for(reader_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end
end
