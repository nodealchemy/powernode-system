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

    # issuer_subject used to be parsed off ca_chain_pem's FIRST cert. Under the
    # chain contract (issuing-first, anchor-last) that expression silently
    # changes referent from "the anchor" to "the issuing CA" — on a PERSISTED
    # column. It is now read off the LEAF's own .issuer, which is what the
    # field name promises and is stable at any chain depth.
    #
    # This pair is the oracle: the value must equal the signing CA's subject
    # AND must be derived from the leaf, not from position 0 of the bundle.
    it "records issuer_subject as the DN of the CA that actually signed the leaf" do
      result = described_class.enroll!(
        bootstrap_token_plaintext: token_plaintext, csr_pem: csr_pem, agent_version: "0.1.0"
      )

      leaf = OpenSSL::X509::Certificate.new(result.cert_pem)
      expect(result.node_certificate.issuer_subject).to eq(leaf.issuer.to_s)
      # At depth 1 the issuing CA IS the anchor, so this is byte-identical to
      # the old behaviour — that equivalence is what makes the change additive.
      expect(result.node_certificate.issuer_subject)
        .to eq(System::InternalCaService.issuing_cert.subject.to_s)
      expect(result.node_certificate.issuer_subject)
        .to eq(System::InternalCaService.anchor_cert.subject.to_s)
    end

    # THE discriminating oracle. At depth 1 the old first-cert-of-chain parse
    # and the new leaf-.issuer read return the SAME string, so no flat fixture
    # can tell them apart — a depth-1-only test here would be hollow. This one
    # hands the service a chain-issued leaf (anchor -> intermediate -> leaf) and
    # asserts issuer_subject is the INTERMEDIATE's DN, which is precisely where
    # the two implementations diverge.
    it "records the INTERMEDIATE's DN for a chain-issued leaf, not the anchor's" do
      anchor_key = OpenSSL::PKey::RSA.new(2048)
      anchor_cert = OpenSSL::X509::Certificate.new.tap do |c|
        c.version = 2; c.serial = 1
        c.subject = c.issuer = OpenSSL::X509::Name.parse("/CN=Test Anchor")
        c.public_key = anchor_key.public_key
        c.not_before = Time.current - 60; c.not_after = Time.current + 3600
        ef = OpenSSL::X509::ExtensionFactory.new(c, c)
        c.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        c.sign(anchor_key, OpenSSL::Digest::SHA256.new)
      end

      inter_key = OpenSSL::PKey::RSA.new(2048)
      inter_cert = OpenSSL::X509::Certificate.new.tap do |c|
        c.version = 2; c.serial = 2
        c.subject = OpenSSL::X509::Name.parse("/CN=Test Intermediate")
        c.issuer = anchor_cert.subject
        c.public_key = inter_key.public_key
        c.not_before = Time.current - 60; c.not_after = Time.current + 3600
        ef = OpenSSL::X509::ExtensionFactory.new(anchor_cert, c)
        c.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        c.sign(anchor_key, OpenSSL::Digest::SHA256.new)
      end

      leaf_key = OpenSSL::PKey::RSA.new(2048)
      leaf_cert = OpenSSL::X509::Certificate.new.tap do |c|
        c.version = 2; c.serial = 3
        c.subject = OpenSSL::X509::Name.parse("/CN=#{instance.id}")
        c.issuer = inter_cert.subject
        c.public_key = leaf_key.public_key
        c.not_before = Time.current - 60; c.not_after = Time.current + 3600
        c.sign(inter_key, OpenSSL::Digest::SHA256.new)
      end

      # Issuing-first, anchor-last (§4.1).
      chain_pem = inter_cert.to_pem + anchor_cert.to_pem

      allow(System::InternalCaService).to receive(:issue_certificate).and_return(
        cert_pem: leaf_cert.to_pem,
        ca_chain_pem: chain_pem,
        serial: "03",
        subject: leaf_cert.subject.to_s,
        not_before: leaf_cert.not_before,
        not_after: leaf_cert.not_after
      )

      result = described_class.enroll!(
        bootstrap_token_plaintext: token_plaintext, csr_pem: csr_pem, agent_version: "0.1.0"
      )

      expect(result.node_certificate.issuer_subject).to eq(inter_cert.subject.to_s)
      # The old parse would have produced the FIRST chain element. Assert the
      # anchor is NOT what got recorded, so a regression to any chain-position
      # read fails here regardless of ordering.
      expect(result.node_certificate.issuer_subject).not_to eq(anchor_cert.subject.to_s)
    end

    it "emits a system.instance_enrolled FleetEvent on success" do
      expect {
        described_class.enroll!(
          bootstrap_token_plaintext: token_plaintext, csr_pem: csr_pem, agent_version: "0.1.0"
        )
      }.to change {
        System::FleetEvent.where(account: account, kind: "system.instance_enrolled").count
      }.by(1)

      ev = System::FleetEvent.where(account: account, kind: "system.instance_enrolled").last
      expect(ev.node_instance_id).to eq(instance.id)
      expect(ev.source).to eq("node_enrollment_service")
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
