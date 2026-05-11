# frozen_string_literal: true

require "rails_helper"
require "openssl"

RSpec.describe System::NodeEnrollmentService do
  before { System::InternalCaService.reset! }

  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let(:keypair) { OpenSSL::PKey.generate_key("ED25519") }
  let(:csr_pem) do
    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.parse("/CN=enroll-cn")
    csr.public_key = keypair
    csr.sign(keypair, nil)
    csr.to_pem
  end

  let(:token_record_and_plain) do
    System::BootstrapToken.issue!(
      node: node, intended_subject: instance.id, node_instance: instance
    )
  end
  let(:token_record)    { token_record_and_plain[0] }
  let(:token_plaintext) { token_record_and_plain[1] }

  describe ".enroll!" do
    it "succeeds with a fresh token + valid CSR" do
      result = described_class.enroll!(
        bootstrap_token_plaintext: token_plaintext,
        csr_pem: csr_pem,
        agent_version: "0.1.0",
        source_ip: "10.1.2.3"
      )

      expect(result.success?).to be true
      expect(result.cert_pem).to include("BEGIN CERTIFICATE")
      expect(result.ca_chain_pem).to include("BEGIN CERTIFICATE")
      expect(result.node_instance).to eq(instance)
      expect(result.node_certificate).to be_a(System::NodeCertificate)
      expect(result.node_certificate.subject).to include(instance.id)
    end

    it "consumes the bootstrap token" do
      described_class.enroll!(
        bootstrap_token_plaintext: token_plaintext, csr_pem: csr_pem,
        source_ip: "10.0.0.1"
      )
      token_record.reload
      expect(token_record.consumed_at).to be_present
      expect(token_record.consumed_from_ip).to eq("10.0.0.1")
    end

    it "stamps mtls_subject + agent_version on the instance" do
      described_class.enroll!(
        bootstrap_token_plaintext: token_plaintext, csr_pem: csr_pem,
        agent_version: "0.2.7"
      )
      instance.reload
      expect(instance.mtls_subject).to eq(instance.id)
      expect(instance.agent_version).to eq("0.2.7")
      expect(instance.enrollment_token_id).to eq(token_record.id)
    end

    it "fails on an unknown / expired / consumed token" do
      result = described_class.enroll!(
        bootstrap_token_plaintext: "not-a-real-token", csr_pem: csr_pem
      )
      expect(result.success?).to be false
      expect(result.error).to match(/invalid or expired/)
    end

    it "fails on a malformed CSR" do
      result = described_class.enroll!(
        bootstrap_token_plaintext: token_plaintext, csr_pem: "this is not a real CSR"
      )
      expect(result.success?).to be false
      expect(result.error).to match(/CSR\/CA failure/)
    end

    it "is idempotent across replay (token can only be consumed once)" do
      described_class.enroll!(
        bootstrap_token_plaintext: token_plaintext, csr_pem: csr_pem
      )
      replay = described_class.enroll!(
        bootstrap_token_plaintext: token_plaintext, csr_pem: csr_pem
      )
      expect(replay.success?).to be false
      expect(replay.error).to match(/invalid or expired/)
    end
  end
end
