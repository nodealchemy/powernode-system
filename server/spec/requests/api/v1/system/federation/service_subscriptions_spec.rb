# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Federation::ServiceSubscriptions", type: :request do
  let(:account) { create(:account) }
  let(:user) do
    user_with_permissions("system.service_subscriptions.read",
                          "system.service_subscriptions.cancel",
                          account: account)
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }
  let(:base_path) { "/api/v1/system/federation/service_subscriptions" }

  let(:peer) { create(:system_federation_peer, :platform, :active, account: account) }

  describe "GET /service_subscriptions" do
    let!(:active_sub) do
      create(:system_federation_service_subscription, :active,
              account: account, federation_peer: peer,
              service_offering_slug: "gitea",
              local_hostname: "git.alice.tld")
    end
    let!(:pending_sub) do
      create(:system_federation_service_subscription,
              account: account, federation_peer: peer,
              service_offering_slug: "managed-pg",
              local_hostname: "pg.alice.tld")
    end
    let!(:other_account_sub) do
      create(:system_federation_service_subscription, :active,
              account: create(:account),
              service_offering_slug: "leak-test",
              local_hostname: "leak.example.com")
    end

    it "lists subscriber's own subscriptions + scopes to current account" do
      get base_path, headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      slugs = body["data"]["subscriptions"].map { |s| s["service_offering_slug"] }
      expect(slugs).to match_array([ "gitea", "managed-pg" ])
      expect(slugs).not_to include("leak-test")
    end

    it "filters by status" do
      get base_path, headers: headers, params: { status: "active" }
      body = JSON.parse(response.body)
      expect(body["data"]["subscriptions"].map { |s| s["status"] }).to eq([ "active" ])
    end

    it "filters by peer_id" do
      get base_path, headers: headers, params: { peer_id: peer.id }
      body = JSON.parse(response.body)
      expect(body["data"]["subscriptions"].size).to eq(2)
    end

    it "rejects without read permission" do
      bare_user = create(:user, account: account)
      get base_path, headers: auth_headers_for(bare_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /service_subscriptions/:id" do
    let!(:sub) do
      create(:system_federation_service_subscription, :active,
              account: account, federation_peer: peer,
              local_hostname: "git.alice.tld")
    end

    it "returns the subscription with full detail including metadata" do
      get "#{base_path}/#{sub.id}", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["subscription"]["local_hostname"]).to eq("git.alice.tld")
      expect(body["data"]["subscription"]).to have_key("federation_grant_id")
      expect(body["data"]["subscription"]).to have_key("acme_certificate_id")
      expect(body["data"]["subscription"]).to have_key("metadata")
    end

    it "404 for subscription in a different account" do
      other_sub = create(:system_federation_service_subscription, :active, account: create(:account))
      get "#{base_path}/#{other_sub.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /service_subscriptions/:id/cancel" do
    let!(:sub) do
      create(:system_federation_service_subscription, :active,
              account: account, federation_peer: peer,
              local_hostname: "git.alice.tld")
    end

    it "cancels the subscription" do
      post "#{base_path}/#{sub.id}/cancel",
           params: { reason: "no longer needed" }.to_json,
           headers: headers
      expect(response).to have_http_status(:ok)
      sub.reload
      expect(sub.status).to eq("cancelled")
      expect(sub.metadata["cancellation_reason"]).to eq("no longer needed")
    end

    it "409 when already cancelled" do
      sub.cancel!(reason: "test")
      post "#{base_path}/#{sub.id}/cancel", headers: headers
      expect(response).to have_http_status(:conflict)
    end

    it "rejects without cancel permission" do
      read_only_user = user_with_permissions("system.service_subscriptions.read", account: account)
      post "#{base_path}/#{sub.id}/cancel",
           headers: auth_headers_for(read_only_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end
end
