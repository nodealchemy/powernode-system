# frozen_string_literal: true

require "rails_helper"
require "openssl"

# Golden Eclipse M0.N — InternalCaService (LocalCaAdapter test path).
# VaultCaAdapter is exercised against a real Vault deployment in integration
# tests; these unit specs cover the local-CA happy path + error cases.
RSpec.describe System::InternalCaService do
  before { described_class.reset! }
  after  { described_class.reset! }

  let(:keypair) { OpenSSL::PKey.generate_key("ED25519") }
  let(:csr_pem) do
    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.parse("/CN=test-instance-uuid")
    csr.public_key = keypair
    csr.sign(keypair, nil)
    csr.to_pem
  end

  describe ".issue_certificate (local adapter)" do
    it "issues a leaf cert signed by the in-memory CA" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test-instance-uuid"
      )

      expect(result[:cert_pem]).to include("BEGIN CERTIFICATE")
      expect(result[:ca_chain_pem]).to include("BEGIN CERTIFICATE")
      expect(result[:serial]).to be_present
      expect(result[:not_before]).to be_within(60.seconds).of(Time.current)
      expect(result[:not_after]).to be_within(60.seconds).of(1.hour.from_now)
    end

    it "issued cert verifies against the CA chain" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test"
      )
      cert = OpenSSL::X509::Certificate.new(result[:cert_pem])
      ca   = OpenSSL::X509::Certificate.new(result[:ca_chain_pem])
      expect(cert.verify(ca.public_key)).to be true
    end

    it "rejects a malformed CSR PEM" do
      expect {
        described_class.issue_certificate(csr_pem: "this is not a CSR", ttl_seconds: 60)
      }.to raise_error(described_class::CsrError, /malformed CSR/)
    end

    it "rejects a CSR whose signature does not verify against its public_key" do
      # Build a CSR signed by one key, then swap its public_key to a different
      # key — signature no longer verifies.
      other = OpenSSL::PKey.generate_key("ED25519")
      csr = OpenSSL::X509::Request.new(csr_pem)
      csr.public_key = other # invalidates the existing signature
      expect {
        described_class.issue_certificate(csr_pem: csr.to_pem, ttl_seconds: 60)
      }.to raise_error(described_class::CsrError, /signature invalid/)
    end

    it "uses the CN from common_name when supplied" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "override-cn"
      )
      cert = OpenSSL::X509::Certificate.new(result[:cert_pem])
      expect(cert.subject.to_s).to eq("/CN=override-cn")
    end
  end

  describe ".ca_chain_pem" do
    it "returns the same root across calls" do
      first  = described_class.ca_chain_pem
      second = described_class.ca_chain_pem
      expect(first).to eq(second)
      expect(first).to include("BEGIN CERTIFICATE")
    end
  end

  describe "adapter selection" do
    it "uses LocalCaAdapter in test environment by default" do
      expect(described_class.adapter).to be_a(described_class::LocalCaAdapter)
    end

    it "honors an explicit POWERNODE_CA_MODE=local override" do
      stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_MODE" => "local"))
      described_class.reset!
      expect(described_class.adapter).to be_a(described_class::LocalCaAdapter)
    end

    it "raises on an unknown mode" do
      stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_MODE" => "wat"))
      described_class.reset!
      expect { described_class.adapter }.to raise_error(described_class::CaError, /Unknown POWERNODE_CA_MODE/)
    end
  end
end
