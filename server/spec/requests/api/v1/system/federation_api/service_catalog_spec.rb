# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::FederationApi::ServiceCatalog", type: :request do
  let(:account) { create(:account) }
  # let! — eagerly create so the peer (and its inbound_subject) exists before
  # the mTLS lookup in BaseController resolves the forwarded CN.
  let!(:peer) { enrolled_federation_peer(account: account, status: "active") }
  let(:mtls_headers) { federation_mtls_headers(peer) }

  let(:path) { "/api/v1/system/federation_api/service_catalog" }

  describe "GET /service_catalog" do
    let!(:active_offering)     { create(:system_federation_service_offering, :active, account: account, slug: "gitea", name: "Hosted Git") }
    let!(:deprecated_offering) { create(:system_federation_service_offering, :deprecated, account: account, slug: "old-svc", name: "Legacy Service") }
    let!(:draft_offering)      { create(:system_federation_service_offering, account: account, slug: "draft-svc") }
    let!(:retired_offering)    { create(:system_federation_service_offering, :retired, account: account, slug: "retired-svc") }

    it "returns active + deprecated offerings" do
      get path, headers: mtls_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      slugs = body["data"]["offerings"].map { |o| o["slug"] }
      expect(slugs).to match_array([ "gitea", "old-svc" ])
    end

    it "does NOT expose backend_host or backend_vip in the catalog" do
      get path, headers: mtls_headers
      body = JSON.parse(response.body)
      body["data"]["offerings"].each do |offering|
        expect(offering).not_to have_key("backend_host")
        expect(offering).not_to have_key("backend_vip")
        expect(offering).not_to have_key("backend_vip_id")
      end
    end

    it "marks accepting_new_subscriptions true for active, false for deprecated" do
      get path, headers: mtls_headers
      body = JSON.parse(response.body)
      gitea = body["data"]["offerings"].find { |o| o["slug"] == "gitea" }
      old_svc = body["data"]["offerings"].find { |o| o["slug"] == "old-svc" }
      expect(gitea["accepting_new_subscriptions"]).to be true
      expect(old_svc["accepting_new_subscriptions"]).to be false
    end

    it "includes generated_at timestamp" do
      get path, headers: mtls_headers
      body = JSON.parse(response.body)
      expect(body["data"]["generated_at"]).to be_present
    end

    it "returns 401 without mTLS auth" do
      get path
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
