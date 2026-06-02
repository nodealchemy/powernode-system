# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::WorkerApi::FederationTrustBundle", type: :request do
  let(:worker)  { create(:worker) }
  let(:headers) { worker_mtls_headers(worker).merge("Content-Type" => "application/json") }
  let(:path)    { "/api/v1/system/worker_api/federation/trust_bundle_refresh" }

  describe "POST /federation/trust_bundle_refresh" do
    let(:refresh_result) do
      ::Federation::TrustBundleRefreshService::Result.new(checked: 2, updated: 1, failures: [])
    end

    before do
      allow(::Federation::TrustBundleRefreshService).to receive(:run!).and_return(refresh_result)
    end

    it "invokes the refresh + returns the result counts" do
      post path, headers: headers
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["checked"]).to eq(2)
      expect(data["updated"]).to eq(1)
    end

    it "401s without a worker token" do
      post path
      expect(response).to have_http_status(:unauthorized)
    end

    it "500s when the refresh raises (diagnostic surfaced)" do
      allow(::Federation::TrustBundleRefreshService).to receive(:run!)
        .and_raise(StandardError, "peer unreachable")
      post path, headers: headers
      expect(response).to have_http_status(:internal_server_error)
      expect(JSON.parse(response.body)["error"]).to match(/peer unreachable/)
    end
  end
end
