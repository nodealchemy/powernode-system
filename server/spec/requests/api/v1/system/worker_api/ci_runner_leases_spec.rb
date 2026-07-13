# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::WorkerApi::CiRunnerLeases", type: :request do
  let(:worker) { create(:worker) }
  let(:headers) { worker_mtls_headers(worker).merge("Content-Type" => "application/json") }
  let(:path) { "/api/v1/system/worker_api/ci_runner_leases/advance" }

  let(:summary) { { advanced: 1, released: 2, flagged: 0, errored: 0, orphans_reaped: 3 } }

  describe "POST /ci_runner_leases/advance" do
    it "401s without a worker token" do
      post path
      expect(response).to have_http_status(:unauthorized)
    end

    it "runs the sweep + returns aggregated counts for a scoped account" do
      allow(::System::CiRunnerLeaseSweepService).to receive(:run!).and_return(summary)

      post path, params: { account_id: worker.account.id }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["accounts_swept"]).to eq(1)
      expect(data["released"]).to eq(2)
      expect(data["orphans_reaped"]).to eq(3)
    end

    # Regression: orphan reaping must reach an account that has offline fleet-*
    # runners but zero active leases (scoping on active leases alone left them
    # unreachable by the cron).
    it "sweeps accounts with orphan fleet-* runners even when they have no active leases" do
      account = create(:account)
      create(:git_runner, :offline, account: account, name: "fleet-orphanacct0001")

      expect(::System::CiRunnerLeaseSweepService).to receive(:run!).with(account: account).and_return(summary)

      post path, headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "500s (never raises) when the sweep errors" do
      allow(::System::CiRunnerLeaseSweepService).to receive(:run!).and_raise(StandardError, "boom")

      post path, params: { account_id: worker.account.id }.to_json, headers: headers

      expect(response).to have_http_status(:internal_server_error)
      expect(JSON.parse(response.body)["error"]).to match(/boom/)
    end
  end
end
