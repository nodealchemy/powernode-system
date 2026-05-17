# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::WorkerApi::AcmeRenewalSweep", type: :request do
  let(:worker) { create(:worker) }
  let(:token)  { ::Security::JwtService.encode({ sub: worker.id, type: "worker" }) }
  let(:headers) { { "X-Worker-Token" => token, "Content-Type" => "application/json" } }

  let(:path) { "/api/v1/system/worker_api/acme/renewal_sweep" }

  describe "POST /acme/renewal_sweep" do
    let(:sweep_result) do
      ::Acme::RenewalSweepService::Result.new(
        ok?: true,
        renewed_count: 3,
        failed_count: 1,
        skipped_count: 0,
        findings: [ { kind: "renewed", cert_id: "abc" } ],
        ran_at: Time.current
      )
    end

    before do
      allow(::Acme::RenewalSweepService).to receive(:run!).and_return(sweep_result)
    end

    it "invokes the sweep + returns the result counts" do
      post path, headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      data = body["data"]
      expect(data["renewed_count"]).to eq(3)
      expect(data["failed_count"]).to eq(1)
      expect(data["ok"]).to be true
      expect(data["ran_at"]).to be_present
    end

    it "401 without worker token" do
      post path
      expect(response).to have_http_status(:unauthorized)
    end

    it "500 when sweep raises (with diagnostic in error)" do
      allow(::Acme::RenewalSweepService).to receive(:run!)
        .and_raise(StandardError, "Vault unavailable")
      post path, headers: headers
      expect(response).to have_http_status(:internal_server_error)
      expect(JSON.parse(response.body)["error"]).to match(/Vault unavailable/)
    end
  end
end
