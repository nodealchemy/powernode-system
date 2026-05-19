# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for slice 7 InstancePools.
#
# Two distinct permission gates apply: read uses system.node_instances.read,
# write uses system.instances.create OR system.instances.control. Create +
# destroy flow through GatedActions (Ai::AutonomyGate) — without a seeded
# policy the gate's default decides 2xx vs pending. Per the audit plan, we
# focus on the auth/permission boundary; the gate-decision branches are
# covered by Ai::AutonomyGate specs and the InstancePoolService specs.
RSpec.describe "Api::V1::System::InstancePools", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.node_instances.read", account: account) }
  let(:write_user)  { user_with_permissions("system.node_instances.read", "system.instances.create", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:template) { create(:system_node_template, account: account) }
  let!(:pool) do
    ::System::InstancePool.create!(
      account: account,
      name: "spec-pool-#{SecureRandom.hex(3)}",
      node_template: template,
      target_size: 1,
      min_size: 0,
      max_size: 5,
      lifecycle_class: "ephemeral",
      status: "active"
    )
  end

  describe "GET /api/v1/system/instance_pools" do
    it "returns 401 without auth" do
      get "/api/v1/system/instance_pools"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/instance_pools", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the caller's pools" do
      get "/api/v1/system/instance_pools", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      ids = json_response_data["pools"].map { |p| p["id"] }
      expect(ids).to include(pool.id)
    end

    it "scopes to the caller's account" do
      foreign_tpl = create(:system_node_template, account: other_account)
      foreign = ::System::InstancePool.create!(
        account: other_account, name: "foreign-pool", node_template: foreign_tpl,
        target_size: 1, min_size: 0, max_size: 5, lifecycle_class: "ephemeral", status: "active"
      )
      get "/api/v1/system/instance_pools", headers: auth_headers_for(read_user)
      ids = json_response_data["pools"].map { |p| p["id"] }
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/instance_pools/:id" do
    it "returns the pool" do
      get "/api/v1/system/instance_pools/#{pool.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["pool"]["id"]).to eq(pool.id)
    end

    it "returns 404 for another account's pool" do
      foreign_tpl = create(:system_node_template, account: other_account)
      foreign = ::System::InstancePool.create!(
        account: other_account, name: "foreign-pool-2", node_template: foreign_tpl,
        target_size: 1, min_size: 0, max_size: 5, lifecycle_class: "ephemeral", status: "active"
      )
      get "/api/v1/system/instance_pools/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/instance_pools/:id/replenish" do
    it "returns 403 without write perm" do
      post "/api/v1/system/instance_pools/#{pool.id}/replenish",
           headers: auth_headers_for(read_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "calls InstancePoolService.replenish! and returns 200" do
      allow(::System::InstancePoolService).to receive(:replenish!).and_return({ ok: true, added: 0 })
      post "/api/v1/system/instance_pools/#{pool.id}/replenish",
           headers: auth_headers_for(write_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(::System::InstancePoolService).to have_received(:replenish!).with(pool: an_instance_of(::System::InstancePool))
    end
  end

  describe "POST /api/v1/system/instance_pools/:id/drain" do
    it "calls InstancePoolService.drain! and returns 200" do
      allow(::System::InstancePoolService).to receive(:drain!).and_return({ ok: true, drained: 0 })
      post "/api/v1/system/instance_pools/#{pool.id}/drain",
           headers: auth_headers_for(write_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/system/instance_pools/:id/recycle_stale" do
    it "calls InstancePoolService.recycle_stale_members! and returns 200" do
      allow(::System::InstancePoolService).to receive(:recycle_stale_members!).and_return({ ok: true })
      post "/api/v1/system/instance_pools/#{pool.id}/recycle_stale",
           headers: auth_headers_for(write_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/system/instance_pools (create)" do
    it "returns 403 without write perm" do
      post "/api/v1/system/instance_pools",
           params: { pool: { name: "x", target_size: 1, node_template_id: template.id } }.to_json,
           headers: auth_headers_for(read_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end
end
