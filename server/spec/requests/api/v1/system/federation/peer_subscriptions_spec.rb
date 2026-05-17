# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Federation::PeerSubscriptions", type: :request do
  let(:account) { create(:account) }
  let(:user) { user_with_permissions("system.service_subscriptions.subscribe", account: account) }
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }
  let(:peer) { create(:system_federation_peer, :platform, :active, account: account) }
  let(:path) { "/api/v1/system/federation/peers/#{peer.id}/subscriptions" }

  let(:stub_client) { instance_double("Federation::PeerClient") }

  let(:operator_response) do
    {
      "grant_id" => SecureRandom.uuid,
      "service_offering_id" => SecureRandom.uuid,
      "backend_host" => "backend.example.com",
      "backend_port" => 443,
      "protocol" => "https",
      "permission_scopes" => %w[read write],
      "expires_at" => 30.days.from_now.iso8601,
      "ttl_seconds" => 30.days.to_i
    }
  end

  let(:lifecycle_result) do
    instance_double(::Federation::SubscriptionLifecycleService::Result,
                    ok?: true,
                    error: nil,
                    subscription: subscription_double)
  end

  let(:subscription_double) do
    instance_double("System::Federation::ServiceSubscription",
                    id: SecureRandom.uuid,
                    service_offering_slug: "gitea",
                    local_hostname: "git.alice.tld",
                    protocol: "https",
                    backend_port: 443,
                    status: "active",
                    federation_peer_id: peer.id,
                    activated_at: Time.current)
  end

  before do
    allow(::Federation::PeerClient).to receive(:new).and_return(stub_client)
    allow(stub_client).to receive(:post_subscription).and_return(operator_response)
    allow(::Federation::SubscriptionLifecycleService).to receive(:activate!).and_return(lifecycle_result)
  end

  describe "POST /peers/:peer_id/subscriptions" do
    let(:body) { { slug: "gitea", local_hostname: "git.alice.tld" } }

    it "calls peer + activates locally + returns 201" do
      post path, params: body.to_json, headers: headers
      expect(response).to have_http_status(:created)
      expect(stub_client).to have_received(:post_subscription).with(
        slug: "gitea",
        local_hostname: "git.alice.tld",
        ttl_days: nil
      )
      expect(::Federation::SubscriptionLifecycleService).to have_received(:activate!).with(
        hash_including(
          account: account,
          federation_peer: peer,
          offering_slug: "gitea",
          local_hostname: "git.alice.tld",
          operator_response: operator_response
        )
      )
      data = JSON.parse(response.body)["data"]["subscription"]
      expect(data["status"]).to eq("active")
    end

    it "passes ttl_days through to PeerClient when supplied" do
      post path, params: body.merge(ttl_days: 90).to_json, headers: headers
      expect(stub_client).to have_received(:post_subscription).with(
        slug: "gitea",
        local_hostname: "git.alice.tld",
        ttl_days: 90
      )
    end

    it "400 when required fields missing" do
      post path, params: { slug: "gitea" }.to_json, headers: headers
      expect(response).to have_http_status(:bad_request)
    end

    it "404 when peer unknown" do
      post "/api/v1/system/federation/peers/#{SecureRandom.uuid}/subscriptions",
           params: body.to_json, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "502 when remote peer rejects (HttpError)" do
      allow(stub_client).to receive(:post_subscription)
        .and_raise(::Federation::PeerClient::HttpError.new("offering at capacity", status: 409))
      post path, params: body.to_json, headers: headers
      expect(response).to have_http_status(:bad_gateway)
    end

    it "503 when peer unreachable" do
      allow(stub_client).to receive(:post_subscription)
        .and_raise(::Federation::PeerClient::ConnectionError, "timeout")
      post path, params: body.to_json, headers: headers
      expect(response).to have_http_status(:service_unavailable)
    end

    it "422 when local lifecycle activation fails" do
      failed_result = instance_double(::Federation::SubscriptionLifecycleService::Result,
                                       ok?: false,
                                       error: "Cert issuance did not complete",
                                       subscription: nil)
      allow(::Federation::SubscriptionLifecycleService).to receive(:activate!).and_return(failed_result)
      post path, params: body.to_json, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/Cert issuance/)
    end

    it "403 without subscribe permission" do
      no_perm = create(:user, account: account)
      post path, params: body.to_json, headers: auth_headers_for(no_perm).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end
end
