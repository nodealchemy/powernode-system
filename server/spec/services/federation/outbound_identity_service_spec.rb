# frozen_string_literal: true

require "rails_helper"

# Federation mTLS Phase 2 (hierarchical) — child-side outbound identity.
# Exercises the real local test CA so the CSR → sign → store round trip is
# verified end to end (no mocking of the crypto path).
RSpec.describe Federation::OutboundIdentityService, type: :service do
  let(:account) { create(:account) }
  let(:peer)    { create(:system_federation_peer, :spawned_child, account: account) }

  describe ".prepare_csr" do
    it "generates an Ed25519 key and a CSR the key validly signs" do
      prepared = described_class.prepare_csr(common_name: "federation-peer")

      expect(prepared.private_key).to be_a(OpenSSL::PKey::PKey)
      csr = OpenSSL::X509::Request.new(prepared.csr_pem)
      expect(csr.verify(csr.public_key)).to be(true)
      expect(csr.subject.to_s).to include("federation-peer")
    end

    it "does not persist anything (key stays in memory until store_issued!)" do
      expect { described_class.prepare_csr }.not_to change(System::NodeCertificate, :count)
    end
  end

  describe ".store_issued!" do
    # Sign the child's CSR with the local test CA, forcing the CN the parent
    # would assign — this is exactly what the acceptance service does.
    let(:prepared) { described_class.prepare_csr }
    let(:issued) do
      System::InternalCaService.issue_certificate(
        csr_pem: prepared.csr_pem,
        ttl_seconds: 90 * 24 * 3600,
        common_name: "fed:#{peer.id}"
      )
    end

    def store!
      described_class.store_issued!(
        peer: peer,
        cert_pem: issued[:cert_pem],
        private_key: prepared.private_key,
        ca_chain_pem: issued[:ca_chain_pem]
      )
    end

    it "persists the parent-signed cert as the peer's outbound_certificate" do
      cert = store!

      expect(peer.reload.outbound_certificate).to eq(cert)
      expect(cert.subject_kind).to eq("federation_peer")
      expect(cert.node_instance_id).to be_nil
      expect(cert.account_id).to eq(account.id)
      expect(cert.subject).to include("fed:#{peer.id}")
    end

    it "seals the cert + child key into the Vault-backed credentials blob" do
      cert  = store!
      creds = cert.reload.credentials

      expect(creds["cert_pem"]).to eq(issued[:cert_pem])
      expect(creds["ca_chain_pem"]).to eq(issued[:ca_chain_pem])
      # the persisted key is exactly the in-memory key we generated — proof
      # it never had to leave the child to be signed.
      expect(creds["private_key_pem"]).to eq(prepared.private_key.private_to_pem)
    end

    it "re-enrollment repoints to a fresh cert, preserving the prior row" do
      first = store!

      prepared2 = described_class.prepare_csr
      issued2   = System::InternalCaService.issue_certificate(
        csr_pem: prepared2.csr_pem, ttl_seconds: 90 * 24 * 3600, common_name: "fed:#{peer.id}"
      )
      second = described_class.store_issued!(
        peer: peer, cert_pem: issued2[:cert_pem],
        private_key: prepared2.private_key, ca_chain_pem: issued2[:ca_chain_pem]
      )

      expect(peer.reload.outbound_certificate).to eq(second)
      expect(System::NodeCertificate.where(id: [ first.id, second.id ]).count).to eq(2)
    end
  end

  describe ".self_issue! (symmetric)" do
    it "signs our outbound cert with OUR own CA and the peer-assigned CN" do
      cert = described_class.self_issue!(peer: peer, common_name: "fed:assigned-by-peer")

      expect(peer.reload.outbound_certificate).to eq(cert)
      leaf = OpenSSL::X509::Certificate.new(cert.credentials["cert_pem"])
      expect(leaf.subject.to_s).to include("fed:assigned-by-peer")
      # Self-issued → verifies against our own CA's public key.
      our_ca = OpenSSL::X509::Certificate.new(System::InternalCaService.ca_chain_pem)
      expect(leaf.verify(our_ca.public_key)).to be(true)
    end
  end
end
