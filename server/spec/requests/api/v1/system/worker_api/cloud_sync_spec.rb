# frozen_string_literal: true

require "rails_helper"

# Comprehensive stabilization sweep P2.1 — hourly cloud-state reconciliation
# request spec.
RSpec.describe "POST /api/v1/system/worker_api/cloud_sync/reconcile", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:plain_token) { "wrk-tok-#{SecureRandom.hex(8)}" }

  before do
    # Stub permission check rather than wrestling with role_permission seeding.
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.cloud_sync.reconcile").and_return(true)

    # Account A: shared provider, 2 enabled regions
    @provider_a = create(:system_provider)
    @connection_a = create(:system_provider_connection,
                           account: account, provider: @provider_a, enabled: true)
    @region_a1 = create(:system_provider_region,
                        account: account, provider: @provider_a, enabled: true)
    @region_a2 = create(:system_provider_region,
                        account: account, provider: @provider_a, enabled: true)

    # Account B: separate provider, simulates cross-tenant isolation
    @provider_b = create(:system_provider)
    @connection_b = create(:system_provider_connection,
                           account: other_account, provider: @provider_b, enabled: true)
    @region_b1 = create(:system_provider_region,
                        account: other_account, provider: @provider_b, enabled: true)

    # Stub CloudSyncService — focus is the controller's iteration / scoping,
    # not the underlying provider adapter behavior (covered in service spec).
    allow(::System::CloudSyncService).to receive(:sync_region_instances)
      .and_return(::System::Runtime::Result.ok(data: { synced_count: 1, updated_count: 0,
                                                       cloud_count: 1, page_count: 1 }))
  end

  context "with a system-scoped worker" do
    let!(:worker) do
      w = create(:worker, :system_worker, status: "active")
      w.update_columns(token_digest: Digest::SHA256.hexdigest(plain_token))
      w
    end
    let(:headers) { { "X-Worker-Token" => plain_token } }

    it "returns 200 and a per-account result list" do
      post "/api/v1/system/worker_api/cloud_sync/reconcile", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body.dig("data", "tick_count")).to be >= 2
    end

    it "iterates every account with an enabled connection" do
      post "/api/v1/system/worker_api/cloud_sync/reconcile", headers: headers

      results = JSON.parse(response.body).dig("data", "results")
      account_ids = results.map { |r| r["account_id"] }
      expect(account_ids).to include(account.id, other_account.id)
    end

    it "calls sync_region_instances for each enabled region" do
      post "/api/v1/system/worker_api/cloud_sync/reconcile", headers: headers

      expect(::System::CloudSyncService).to have_received(:sync_region_instances)
        .with(region: @region_a1, account: account)
      expect(::System::CloudSyncService).to have_received(:sync_region_instances)
        .with(region: @region_a2, account: account)
      expect(::System::CloudSyncService).to have_received(:sync_region_instances)
        .with(region: @region_b1, account: other_account)
    end

    it "rescues per-region failures so one bad region doesn't fail the tick" do
      allow(::System::CloudSyncService).to receive(:sync_region_instances)
        .with(region: @region_a1, account: account)
        .and_return(::System::Runtime::Result.err(error: "Provider unreachable"))

      post "/api/v1/system/worker_api/cloud_sync/reconcile", headers: headers

      expect(response).to have_http_status(:ok)
      results = JSON.parse(response.body).dig("data", "results")
      account_a_result = results.find { |r| r["account_id"] == account.id }
      expect(account_a_result["ok"]).to be false
      expect(account_a_result["errors"]).to be_an(Array)
    end

    it "rescues per-account exceptions so one broken account doesn't fail the tick" do
      allow(::System::CloudSyncService).to receive(:sync_region_instances)
        .with(region: @region_b1, account: other_account)
        .and_raise(StandardError, "DB blew up")

      post "/api/v1/system/worker_api/cloud_sync/reconcile", headers: headers

      expect(response).to have_http_status(:ok)
      results = JSON.parse(response.body).dig("data", "results")
      account_b_result = results.find { |r| r["account_id"] == other_account.id }
      expect(account_b_result["ok"]).to be false
      expect(account_b_result["errors"]).to be_an(Array)
    end
  end

  context "with an account-scoped worker" do
    let!(:worker) do
      w = create(:worker, account: account, status: "active")
      w.update_columns(token_digest: Digest::SHA256.hexdigest(plain_token))
      w
    end
    let(:headers) { { "X-Worker-Token" => plain_token } }

    it "only reconciles the worker's own account" do
      post "/api/v1/system/worker_api/cloud_sync/reconcile", headers: headers

      results = JSON.parse(response.body).dig("data", "results")
      account_ids = results.map { |r| r["account_id"] }
      expect(account_ids).to contain_exactly(account.id)
    end
  end

  context "without the system.cloud_sync.reconcile permission" do
    let!(:worker) do
      w = create(:worker, account: account, status: "active")
      w.update_columns(token_digest: Digest::SHA256.hexdigest(plain_token))
      w
    end
    let(:headers) { { "X-Worker-Token" => plain_token } }

    before do
      allow_any_instance_of(Worker).to receive(:has_permission?)
        .with("system.cloud_sync.reconcile").and_return(false)
    end

    it "returns 403" do
      post "/api/v1/system/worker_api/cloud_sync/reconcile", headers: headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
