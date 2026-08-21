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

  # IMP-ce5d320d3e4e — a refusal must HALT the action, not merely render.
  #
  # These examples replace an earlier "returns 403 without write perm" that
  # asserted the STATUS ONLY. It passed while the bug was live: authorize_write!
  # used `render_error(...) and return`, which returns from the HELPER, so the
  # 403 really was rendered — and then the action ran on into the write. The
  # second render raised DoubleRenderError, which ApiResponse's `unless
  # performed?` rescue swallows, so the caller saw a clean 403 over a committed
  # write. A status-only oracle on a refusal path cannot see that; the oracle
  # has to be ABSENCE OF EFFECT.
  #
  # The account is put on notify_and_proceed for both gated categories on
  # purpose: under the require_approval default the smuggled write hides behind
  # a parked Ai::DeferredOperation, so a row-count oracle would measure the
  # wrong thing and pass for the wrong reason. Here the gate executes INLINE,
  # so the pool is really created if the action is not halted.
  #
  # Every one of the eight inline call sites gets an example — six
  # authorize_write! (create/update/destroy/replenish/drain/recycle_stale) and
  # two authorize_read! (index/show). A halt that covers create but not
  # recycle_stale is the same defect with a smaller surface.
  describe "a refused caller (authorization must halt the action)" do
    before do
      %w[system.instance_pool_create system.instance_pool_delete].each do |category|
        ::Ai::InterventionPolicy.create!(
          account: account, ai_agent_id: nil, scope: "action_type",
          action_category: category, policy: "notify_and_proceed",
          priority: 5, is_active: true
        )
      end
    end

    def json_headers(user)
      auth_headers_for(user).merge("Content-Type" => "application/json")
    end

    # --- authorize_write! call sites -------------------------------------

    it "create: writes no pool, opens no deferred operation, mints no approval" do
      before_counts = [
        ::System::InstancePool.count,
        ::Ai::DeferredOperation.count,
        ::Ai::ApprovalRequest.count
      ]

      post "/api/v1/system/instance_pools",
           params: { pool: { name: "smuggled-pool", node_template_id: template.id,
                             target_size: 1, min_size: 0, max_size: 5,
                             lifecycle_class: "ephemeral" } }.to_json,
           headers: json_headers(read_user)

      expect(response).to have_http_status(:forbidden)
      expect(::System::InstancePool.find_by(name: "smuggled-pool")).to be_nil,
                                                                      "the refused caller's pool was created behind the 403"
      expect([ ::System::InstancePool.count,
               ::Ai::DeferredOperation.count,
               ::Ai::ApprovalRequest.count ]).to eq(before_counts)
    end

    it "update: leaves the pool's attributes untouched" do
      patch "/api/v1/system/instance_pools/#{pool.id}",
            params: { pool: { target_size: 4, description: "owned" } }.to_json,
            headers: json_headers(read_user)

      expect(response).to have_http_status(:forbidden)
      pool.reload
      expect(pool.target_size).to eq(1)
      expect(pool.description).not_to eq("owned")
    end

    it "destroy: does not archive the pool, opens no deferred operation, mints no approval" do
      before_counts = [ ::Ai::DeferredOperation.count, ::Ai::ApprovalRequest.count ]

      delete "/api/v1/system/instance_pools/#{pool.id}", headers: json_headers(read_user)

      expect(response).to have_http_status(:forbidden)
      expect(pool.reload.status).to eq("active")
      expect([ ::Ai::DeferredOperation.count, ::Ai::ApprovalRequest.count ]).to eq(before_counts)
    end

    it "replenish: never reaches InstancePoolService.replenish!" do
      allow(::System::InstancePoolService).to receive(:replenish!).and_return({ ok: true })

      post "/api/v1/system/instance_pools/#{pool.id}/replenish", headers: json_headers(read_user)

      expect(response).to have_http_status(:forbidden)
      expect(::System::InstancePoolService).not_to have_received(:replenish!)
    end

    it "drain: never reaches InstancePoolService.drain!" do
      allow(::System::InstancePoolService).to receive(:drain!).and_return({ ok: true })

      post "/api/v1/system/instance_pools/#{pool.id}/drain", headers: json_headers(read_user)

      expect(response).to have_http_status(:forbidden)
      expect(::System::InstancePoolService).not_to have_received(:drain!)
    end

    it "recycle_stale: never reaches InstancePoolService.recycle_stale_members!" do
      allow(::System::InstancePoolService).to receive(:recycle_stale_members!).and_return({ ok: true })

      post "/api/v1/system/instance_pools/#{pool.id}/recycle_stale", headers: json_headers(read_user)

      expect(response).to have_http_status(:forbidden)
      expect(::System::InstancePoolService).not_to have_received(:recycle_stale_members!)
    end

    # --- authorize_read! call sites --------------------------------------
    #
    # A read has no row to count, so the effect measured is the action body
    # running at all: pre-fix the listing query and the serializer both ran
    # behind the already-rendered 403.

    it "index: never runs the pool listing query" do
      allow(::System::InstancePool).to receive(:for_account).and_call_original

      get "/api/v1/system/instance_pools", headers: json_headers(no_perms)

      expect(response).to have_http_status(:forbidden)
      expect(::System::InstancePool).not_to have_received(:for_account)
    end

    it "show: never serializes the pool" do
      serialized = false
      allow_any_instance_of(::System::InstancePool).to receive(:to_summary) do
        serialized = true
        {}
      end

      get "/api/v1/system/instance_pools/#{pool.id}", headers: json_headers(no_perms)

      expect(response).to have_http_status(:forbidden)
      expect(serialized).to be(false),
                            "the action serialized the pool after the 403 was already rendered"
    end
  end

  # D6 — cross-AZ replenishment: preferred_regions must be writable so
  # InstancePoolService#pick_region_for_slot has a list to round-robin.
  describe "PATCH /api/v1/system/instance_pools/:id (preferred_regions)" do
    it "sets and then clears preferred_regions" do
      r1 = create(:system_provider_region, account: account)
      r2 = create(:system_provider_region, account: account)

      patch "/api/v1/system/instance_pools/#{pool.id}",
            params: { pool: { preferred_regions: [ r1.id, r2.id ] } }.to_json,
            headers: auth_headers_for(write_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(pool.reload.preferred_regions).to eq([ r1.id, r2.id ])

      patch "/api/v1/system/instance_pools/#{pool.id}",
            params: { pool: { preferred_regions: [] } }.to_json,
            headers: auth_headers_for(write_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(pool.reload.preferred_regions).to eq([])
    end
  end
end
