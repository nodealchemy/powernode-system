# frozen_string_literal: true

require "rails_helper"

RSpec.describe Federation::SubscriptionLifecycleService, type: :service do
  let(:subscriber_account) { create(:account) }
  let(:operator_peer) do
    create(:system_federation_peer, :platform, :active, account: subscriber_account)
  end
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: subscriber_account) }

  # Stub ACME client returns canned valid cert material.
  let(:cert_material) do
    {
      cert_pem: "-----BEGIN CERT-----\nstub\n-----END CERT-----",
      key_pem: "-----BEGIN KEY-----\nstub\n-----END KEY-----",
      chain_pem: "-----BEGIN CHAIN-----\nstub\n-----END CHAIN-----",
      account_key_pem: "-----BEGIN ACCT-----\nstub\n-----END ACCT-----",
      issued_at: Time.current,
      expires_at: 90.days.from_now
    }
  end
  let(:stub_client) do
    instance_double("Acme::LegoClient",
                    issue: cert_material,
                    renew: cert_material,
                    revoke: true)
  end
  let(:fake_vault) { instance_double("Security::VaultCredentialProvider") }

  before do
    allow(::Security::VaultCredentialProvider).to receive(:new).and_return(fake_vault)
    allow(fake_vault).to receive(:get_credential).and_return("api_token" => "stub-token")
    allow(fake_vault).to receive(:store_credential).and_return(true)
    # Stub the Traefik writer so we don't actually touch the filesystem
    allow(::Federation::ServiceRouteWriter).to receive(:write!).and_return(output_path: "/tmp/stub", route_count: 1)
  end

  # Build a synthetic operator response (the shape ServiceCatalogService
  # returns in `result.connection`).
  let(:base_response) do
    {
      grant_id: SecureRandom.uuid,
      service_offering_id: SecureRandom.uuid,
      backend_host: "backend.example.com",
      backend_port: 443,
      protocol: "https",
      permission_scopes: %w[read write],
      expires_at: 30.days.from_now.iso8601,
      ttl_seconds: 30.days.to_i
    }
  end

  describe ".activate! happy path (https subscription)" do
    it "creates the subscription, grant, cert, and activates the subscription" do
      result = described_class.activate!(
        account: subscriber_account,
        federation_peer: operator_peer,
        offering_slug: "gitea",
        local_hostname: "git.alice.tld",
        operator_response: base_response,
        dns_credential: dns_cred,
        acme_client: stub_client
      )
      expect(result.ok?).to be true
      sub = result.subscription
      expect(sub).to be_persisted
      expect(sub.status).to eq("active")
      expect(sub.federation_grant).to be_persisted
      expect(sub.acme_certificate.status).to eq("valid")
      expect(sub.metadata["operator_response"]["grant_id"]).to eq(base_response[:grant_id])
    end

    it "records the received bearer token + remote grant id in local grant metadata" do
      result = described_class.activate!(
        account: subscriber_account, federation_peer: operator_peer,
        offering_slug: "gitea", local_hostname: "git.alice.tld",
        operator_response: base_response, dns_credential: dns_cred,
        acme_client: stub_client
      )
      expect(result.grant.metadata["remote_grant_id"]).to eq(base_response[:grant_id])
      expect(result.grant.metadata["received_from_peer_id"]).to eq(operator_peer.id)
    end

    it "invokes ServiceRouteWriter on the subscriber's account" do
      described_class.activate!(
        account: subscriber_account, federation_peer: operator_peer,
        offering_slug: "gitea", local_hostname: "git.alice.tld",
        operator_response: base_response, dns_credential: dns_cred,
        acme_client: stub_client
      )
      expect(::Federation::ServiceRouteWriter).to have_received(:write!)
        .with(account: subscriber_account)
    end
  end

  describe ".activate! for plain-http subscription (no cert)" do
    let(:http_response) { base_response.merge(protocol: "http") }

    it "creates the subscription without an AcmeCertificate" do
      result = described_class.activate!(
        account: subscriber_account, federation_peer: operator_peer,
        offering_slug: "internal-svc", local_hostname: "internal.alice.tld",
        operator_response: http_response,
        acme_client: stub_client
      )
      expect(result.ok?).to be true
      expect(result.subscription.acme_certificate).to be_nil
      expect(result.subscription.status).to eq("active")
    end
  end

  describe ".activate! for site-local TCP forward (no cert, no Traefik route)" do
    let(:tcp_response) do
      base_response.merge(protocol: "tcp", backend_port: 5432, backend_host: "fd00:abc::20")
    end

    it "creates the subscription without cert and skips ServiceRouteWriter" do
      result = described_class.activate!(
        account: subscriber_account, federation_peer: operator_peer,
        offering_slug: "managed-pg", local_hostname: "localhost:5432",
        operator_response: tcp_response,
        acme_client: stub_client
      )
      expect(result.ok?).to be true
      expect(result.subscription.acme_certificate).to be_nil
      expect(result.subscription.site_local?).to be true
      expect(::Federation::ServiceRouteWriter).not_to have_received(:write!)
    end
  end

  describe ".activate! when cert issuance fails" do
    before do
      allow(stub_client).to receive(:issue).and_raise(StandardError, "DNS provider rate-limited")
    end

    it "returns failure + leaves the cert in failed state for retry" do
      result = described_class.activate!(
        account: subscriber_account, federation_peer: operator_peer,
        offering_slug: "gitea", local_hostname: "git.alice.tld",
        operator_response: base_response, dns_credential: dns_cred,
        acme_client: stub_client
      )
      expect(result.ok?).to be false
      expect(result.error).to match(/Cert issuance did not complete/)
      expect(result.certificate.status).to eq("failed")
    end

    it "does NOT create a subscription when cert fails" do
      expect {
        described_class.activate!(
          account: subscriber_account, federation_peer: operator_peer,
          offering_slug: "gitea", local_hostname: "git.alice.tld",
          operator_response: base_response, dns_credential: dns_cred,
          acme_client: stub_client
        )
      }.not_to change { ::System::Federation::ServiceSubscription.count }
    end
  end

  describe ".activate! with malformed operator_response" do
    it "returns failure when required keys are missing" do
      result = described_class.activate!(
        account: subscriber_account, federation_peer: operator_peer,
        offering_slug: "gitea", local_hostname: "git.alice.tld",
        operator_response: { grant_id: "abc" },  # missing backend_host/port/protocol
        dns_credential: dns_cred,
        acme_client: stub_client
      )
      expect(result.ok?).to be false
      expect(result.error).to match(/missing required keys/)
    end
  end

  describe ".activate! reuses an existing valid cert for the same hostname" do
    let!(:existing_cert) do
      create(:system_acme_certificate, :valid, account: subscriber_account,
                                                dns_credential: dns_cred,
                                                common_name: "git.alice.tld",
                                                expires_at: 60.days.from_now)
    end

    it "links the existing cert without re-issuing" do
      described_class.activate!(
        account: subscriber_account, federation_peer: operator_peer,
        offering_slug: "gitea", local_hostname: "git.alice.tld",
        operator_response: base_response, dns_credential: dns_cred,
        acme_client: stub_client
      )
      # CertificateManager.issue! should not have been called
      expect(stub_client).not_to have_received(:issue)
      expect(::System::Federation::ServiceSubscription.last.acme_certificate_id)
        .to eq(existing_cert.id)
    end
  end
end
