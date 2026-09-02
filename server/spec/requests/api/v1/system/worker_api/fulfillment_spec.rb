# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc-O — worker-callable FulfillmentRequest sweep.
# Mirrors spec/requests/api/v1/system/worker_api/ci_runner_leases_spec.rb
# (the sweep service's own documented analog): mTLS-gated, aggregates
# per-account summaries, and scopes accounts to reach orphaned task-scoped
# instances even when their owning request has already been archived.
RSpec.describe "Api::V1::System::WorkerApi::Fulfillment", type: :request do
  let(:worker) { create(:worker) }
  let(:headers) { worker_mtls_headers(worker).merge("Content-Type" => "application/json") }
  let(:path) { "/api/v1/system/worker_api/fulfillment/sweep" }

  let(:summary) do
    { advanced: 1, reached_ready: 1, failed: 0, waiting: 0,
      requests_expired: 1, instances_reaped: 2, errored: 0 }
  end

  describe "POST /fulfillment/sweep" do
    it "401s without a worker token" do
      post path
      expect(response).to have_http_status(:unauthorized)
    end

    it "runs the sweep + returns aggregated counts for a scoped account" do
      allow(::System::FulfillmentRequestSweepService).to receive(:run!).and_return(summary)

      post path, params: { account_id: worker.account.id }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["accounts_swept"]).to eq(1)
      expect(data["advanced"]).to eq(1)
      expect(data["requests_expired"]).to eq(1)
      expect(data["instances_reaped"]).to eq(2)
    end

    # Regression (mirrors the ci_runner_lease orphan-runner fix): the sweep
    # must reach an account that has a stray task_scoped instance but zero
    # open FulfillmentRequests — scoping on open requests alone would leave
    # it unreachable by the cron.
    it "sweeps accounts with a stray task_scoped instance even when they have no open requests" do
      account = create(:account)
      platform = create(:system_node_platform, account: account)
      template = create(:system_node_template, account: account, node_platform: platform)
      node = create(:system_node, account: account, node_template: template)
      inst = create(:system_node_instance, :running, node: node)
      inst.update!(lease_class: "task_scoped", lease_expires_at: 1.minute.ago)

      expect(::System::FulfillmentRequestSweepService).to receive(:run!).with(account: account).and_return(summary)

      post path, headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "500s (never raises) when the sweep errors" do
      allow(::System::FulfillmentRequestSweepService).to receive(:run!).and_raise(StandardError, "boom")

      post path, params: { account_id: worker.account.id }.to_json, headers: headers

      expect(response).to have_http_status(:internal_server_error)
      expect(JSON.parse(response.body)["error"]).to match(/boom/)
    end
  end
end
