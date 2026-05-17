# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::WorkerApi::SubscriptionMonitor", type: :request do
  let(:worker) { create(:worker) }
  let(:token)  { ::Security::JwtService.encode({ sub: worker.id, type: "worker" }) }
  let(:headers) { { "X-Worker-Token" => token, "Content-Type" => "application/json" } }

  let(:path) { "/api/v1/system/worker_api/federation/subscription_monitor" }

  describe "POST /federation/subscription_monitor" do
    let(:sweep_result) do
      ::Federation::SubscriptionMonitorService::Result.new(
        ok?: true,
        suspended_count: 2,
        cert_retried_count: 1,
        auto_cancelled_count: 0,
        findings: [ { kind: "suspended_expired_grant", subscription_id: "abc" } ],
        ran_at: Time.current
      )
    end

    before do
      allow(::Federation::SubscriptionMonitorService).to receive(:run!).and_return(sweep_result)
    end

    it "invokes the sweep + returns the result counts" do
      post path, headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      data = body["data"]
      expect(data["suspended_count"]).to eq(2)
      expect(data["cert_retried_count"]).to eq(1)
      expect(data["auto_cancelled_count"]).to eq(0)
      expect(data["ok"]).to be true
      expect(data["findings"].first["kind"]).to eq("suspended_expired_grant")
    end

    it "401 without worker token" do
      post path
      expect(response).to have_http_status(:unauthorized)
    end

    it "500 when sweep raises" do
      allow(::Federation::SubscriptionMonitorService).to receive(:run!)
        .and_raise(StandardError, "DB unavailable")
      post path, headers: headers
      expect(response).to have_http_status(:internal_server_error)
    end
  end
end
