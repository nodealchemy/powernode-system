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

    it "adds a subjectAltName extension (DNS + IP) when sans are supplied" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "localhost",
        sans: [ "localhost", "127.0.0.1" ]
      )
      cert = OpenSSL::X509::Certificate.new(result[:cert_pem])
      san  = cert.extensions.find { |e| e.oid == "subjectAltName" }
      expect(san).to be_present
      expect(san.value).to include("DNS:localhost")
      expect(san.value).to include("IP Address:127.0.0.1")
    end

    it "omits subjectAltName when no sans are supplied (client certs stay SAN-free)" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test-instance-uuid"
      )
      cert = OpenSSL::X509::Certificate.new(result[:cert_pem])
      expect(cert.extensions.map(&:oid)).not_to include("subjectAltName")
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

    context "in production with POWERNODE_CA_MODE unset (Vault-less auto-detect)" do
      before do
        stub_const("ENV", ENV.to_h.tap { |h| h.delete("POWERNODE_CA_MODE") })
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        described_class.reset!
      end

      it "falls back to LocalCaAdapter when Vault is unconfigured/unavailable" do
        allow(::Security::VaultClient).to receive(:healthy?).and_return(false)
        expect(described_class.adapter).to be_a(described_class::LocalCaAdapter)
      end

      it "treats a raising Vault probe as unusable and still uses local (fail-closed)" do
        allow(::Security::VaultClient).to receive(:healthy?).and_raise(StandardError, "no VAULT_ADDR")
        expect(described_class.adapter).to be_a(described_class::LocalCaAdapter)
      end

      it "selects VaultCaAdapter when Vault is configured + healthy" do
        allow(::Security::VaultClient).to receive(:healthy?).and_return(true)
        fake = instance_double(described_class::VaultCaAdapter)
        allow(described_class::VaultCaAdapter).to receive(:new).and_return(fake)
        expect(described_class.adapter).to be(fake)
      end

      it "an explicit POWERNODE_CA_MODE=vault still wins over auto-detect" do
        stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_MODE" => "vault"))
        described_class.reset!
        fake = instance_double(described_class::VaultCaAdapter)
        allow(described_class::VaultCaAdapter).to receive(:new).and_return(fake)
        # healthy? must NOT be consulted when the mode is explicit
        expect(::Security::VaultClient).not_to receive(:healthy?)
        expect(described_class.adapter).to be(fake)
      end
    end
  end

  describe "LocalCaAdapter on-disk persistence" do
    it "generates + persists a root (key 0600) on first use, then reloads the SAME root" do
      Dir.mktmpdir do |dir|
        stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR" => dir))
        first = described_class::LocalCaAdapter.new

        key_path  = File.join(dir, "root.key")
        cert_path = File.join(dir, "root.crt")
        expect(File.exist?(key_path)).to be(true)
        expect(File.exist?(cert_path)).to be(true)
        expect(format("%o", File.stat(key_path).mode & 0o777)).to eq("600")

        # A second adapter over the same dir loads the persisted root rather
        # than generating a new one — cross-process stability.
        second = described_class::LocalCaAdapter.new
        expect(second.ca_cert.to_pem).to eq(first.ca_cert.to_pem)
      end
    end

    it "signs a CSR that verifies against the persisted CA root (gen→sign→verify)" do
      Dir.mktmpdir do |dir|
        stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR" => dir))
        adapter = described_class::LocalCaAdapter.new
        result  = adapter.issue_certificate(csr_pem: csr_pem, ttl_seconds: 3600, common_name: "node-x")

        leaf  = OpenSSL::X509::Certificate.new(result[:cert_pem])
        store = OpenSSL::X509::Store.new
        store.add_cert(adapter.ca_cert)
        expect(store.verify(leaf)).to be(true)
      end
    end
  end

  # Regression: emit_audit_event! passed `event_type:` to AuditLog.create!,
  # but the column is `action` — every call raised ActiveRecord::RecordInvalid /
  # NoMethodError, silently swallowed by the surrounding rescue, so no CA
  # issue/revoke event was ever actually recorded to the audit log despite
  # ALL key operations being required to be audited.
  describe "audit logging" do
    before { create(:account, name: "System") }

    it "records an audit log entry with action (not event_type) on issue" do
      expect {
        described_class.issue_certificate(csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test-instance-uuid")
      }.to change(AuditLog, :count).by(1)

      log = AuditLog.last
      expect(log.action).to eq("system.internal_ca.issue")
      expect(log.resource_type).to eq("InternalCaCertificate")
      expect(log.resource_id).to be_present
      expect(log.source).to eq("system")
    end

    it "records an audit log entry on revoke" do
      issued = described_class.issue_certificate(csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test")

      expect {
        described_class.revoke_certificate(serial: issued[:serial])
      }.to change(AuditLog, :count).by(1)

      log = AuditLog.last
      expect(log.action).to eq("system.internal_ca.revoke")
      expect(log.resource_id).to eq(issued[:serial].to_s)
    end

    it "never blocks certificate issuance even if no account can be resolved for the audit row" do
      Account.destroy_all

      result = nil
      expect {
        result = described_class.issue_certificate(csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test")
      }.not_to raise_error

      expect(result[:cert_pem]).to include("BEGIN CERTIFICATE")
    end
  end
end
