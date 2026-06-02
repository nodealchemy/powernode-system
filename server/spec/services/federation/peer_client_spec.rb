# frozen_string_literal: true

require "rails_helper"

RSpec.describe Federation::PeerClient, type: :service do
  let(:account) { create(:account) }
  let(:peer) do
    create(:system_federation_peer, :platform, :active, account: account,
           remote_instance_url: "https://peer.example.com",
           endpoints: [ { "url" => "https://lan.peer.example.com", "scope" => "lan", "priority" => 1 } ])
  end

  let(:stub_http) { instance_double("Federation::NetHttpAdapter") }

  def good_response(body)
    { status: 200, body: body.to_json }
  end

  # Federation mTLS Phase 2 — the client presents the peer's
  # outbound_certificate (our key + the parent-signed cert) on outbound calls.
  describe "outbound mTLS identity" do
    it "extracts the cert + key from the peer's outbound_certificate" do
      prepared = Federation::OutboundIdentityService.prepare_csr
      issued = System::InternalCaService.issue_certificate(
        csr_pem: prepared.csr_pem, ttl_seconds: 90 * 24 * 3600, common_name: "fed:#{peer.id}"
      )
      Federation::OutboundIdentityService.store_issued!(
        peer: peer, cert_pem: issued[:cert_pem],
        private_key: prepared.private_key, ca_chain_pem: issued[:ca_chain_pem]
      )

      client = described_class.new(peer: peer.reload, http_client: stub_http)
      expect(client.send(:extract_client_cert_pem)).to eq(issued[:cert_pem])
      expect(client.send(:extract_client_key_pem)).to eq(prepared.private_key.private_to_pem)
    end

    it "returns nil cert material when the peer has no outbound_certificate" do
      client = described_class.new(peer: peer, http_client: stub_http)
      expect(client.send(:extract_client_cert_pem)).to be_nil
      expect(client.send(:extract_client_key_pem)).to be_nil
    end
  end

  describe "#fetch_catalog" do
    it "calls the peer's lan endpoint first (highest priority)" do
      allow(stub_http).to receive(:get).and_return(
        good_response(data: { offerings: [ { slug: "gitea" } ], generated_at: "now" })
      )
      client = described_class.new(peer: peer, http_client: stub_http)
      catalog = client.fetch_catalog
      expect(stub_http).to have_received(:get)
        .with("https://lan.peer.example.com/api/v1/system/federation_api/service_catalog",
              headers: hash_including("Accept" => "application/json"))
      expect(catalog["offerings"]).to eq([ { "slug" => "gitea" } ])
    end

    it "falls back to remote_instance_url when endpoints is empty" do
      peer.update!(endpoints: [])
      allow(stub_http).to receive(:get).and_return(good_response(data: { offerings: [] }))
      described_class.new(peer: peer, http_client: stub_http).fetch_catalog
      expect(stub_http).to have_received(:get)
        .with("https://peer.example.com/api/v1/system/federation_api/service_catalog", anything)
    end

    it "raises HttpError on 4xx with the error message" do
      allow(stub_http).to receive(:get).and_return(status: 404, body: { error: "not found" }.to_json)
      client = described_class.new(peer: peer, http_client: stub_http)
      expect { client.fetch_catalog }.to raise_error(described_class::HttpError, /not found/)
    end

    it "raises ConnectionError on 5xx (remote server error)" do
      allow(stub_http).to receive(:get).and_return(status: 503, body: "")
      client = described_class.new(peer: peer, http_client: stub_http)
      expect { client.fetch_catalog }.to raise_error(described_class::ConnectionError)
    end

    it "raises ConnectionError on status=0 (network unreachable)" do
      allow(stub_http).to receive(:get).and_return(status: 0, body: "")
      client = described_class.new(peer: peer, http_client: stub_http)
      expect { client.fetch_catalog }.to raise_error(described_class::ConnectionError)
    end
  end

  describe "#post_subscription" do
    it "POSTs slug + local_hostname + optional ttl_days" do
      response = good_response(data: { grant_id: "abc", backend_host: "x", backend_port: 443, protocol: "https" })
      allow(stub_http).to receive(:post).and_return(response)
      client = described_class.new(peer: peer, http_client: stub_http)
      result = client.post_subscription(slug: "gitea", local_hostname: "git.alice.tld", ttl_days: 30)

      expect(stub_http).to have_received(:post).with(
        "https://lan.peer.example.com/api/v1/system/federation_api/subscriptions",
        body: { slug: "gitea", local_hostname: "git.alice.tld", ttl_days: 30 }.to_json,
        headers: hash_including("Content-Type" => "application/json")
      )
      expect(result["grant_id"]).to eq("abc")
    end

    it "omits ttl_days from body when nil" do
      response = good_response(data: { grant_id: "abc" })
      allow(stub_http).to receive(:post).and_return(response)
      described_class.new(peer: peer, http_client: stub_http)
                     .post_subscription(slug: "x", local_hostname: "y.example.com")
      expect(stub_http).to have_received(:post).with(
        anything,
        body: %({"slug":"x","local_hostname":"y.example.com"}),
        headers: anything
      )
    end
  end

  describe "#delete_subscription" do
    it "DELETEs by grant id" do
      allow(stub_http).to receive(:delete).and_return(good_response(data: { revoked: true }))
      described_class.new(peer: peer, http_client: stub_http).delete_subscription(grant_id: "abc123")
      expect(stub_http).to have_received(:delete).with(
        "https://lan.peer.example.com/api/v1/system/federation_api/subscriptions/abc123",
        headers: anything
      )
    end
  end

  describe "URL resolution" do
    it "uses remote_instance_url when endpoints is empty" do
      peer.update!(endpoints: [])
      allow(stub_http).to receive(:get).and_return(good_response(data: { offerings: [] }))
      described_class.new(peer: peer, http_client: stub_http).fetch_catalog
      expect(stub_http).to have_received(:get).with(
        "https://peer.example.com/api/v1/system/federation_api/service_catalog",
        anything
      )
    end
  end
end
