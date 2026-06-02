# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::FederationApi::TrustBundle", type: :request do
  let(:account) { create(:account) }
  let(:peer)    { enrolled_federation_peer(account: account) }
  let(:path)    { "/api/v1/system/federation_api/trust_bundle" }

  it "returns our CA bundle to an authenticated peer" do
    get path, headers: federation_mtls_headers(peer)
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["data"]["ca_bundle_pem"]).to include("BEGIN CERTIFICATE")
    expect(body["data"]["generated_at"]).to be_present
  end

  it "401s without an mTLS subject" do
    get path
    expect(response).to have_http_status(:unauthorized)
  end
end
