# frozen_string_literal: true

require "rails_helper"

# Federation mTLS Phase 2 (symmetric) — both sides of the CA-anchor exchange.
RSpec.describe Federation::PeerTrustService, type: :service do
  let(:account) { create(:account) }
  # A platform peer of equals (symmetric spawn_role, out_of_band).
  let(:peer) { create(:system_federation_peer, :platform, account: account, status: "accepted") }

  # Stand-in for the OTHER platform's CA bundle (any PEM — we only store it).
  let(:peer_ca_pem) { "-----BEGIN CERTIFICATE-----\nPEERCA\n-----END CERTIFICATE-----\n" }

  describe ".establish_from_request! (server side)" do
    subject(:result) do
      described_class.establish_from_request!(
        peer: peer,
        peer_ca_bundle_pem: peer_ca_pem,
        caller_inbound_subject: "fed:caller-assigned-xyz"
      )
    end

    it "trusts the caller's CA and assigns our own inbound_subject" do
      result
      peer.reload
      expect(peer.trusted_ca_pem).to eq(peer_ca_pem)
      expect(peer.inbound_subject).to eq("fed:#{peer.id}")
    end

    it "self-issues our outbound cert with the CN the caller assigned us" do
      result
      cert = peer.reload.outbound_certificate
      expect(cert).to be_present
      expect(cert.subject_kind).to eq("federation_peer")
      leaf = OpenSSL::X509::Certificate.new(cert.credentials["cert_pem"])
      expect(leaf.subject.to_s).to include("fed:caller-assigned-xyz")
    end

    it "returns our CA bundle + the subject we assigned, for the response" do
      expect(result[:ca_bundle_pem]).to include("BEGIN CERTIFICATE")
      expect(result[:assigned_inbound_subject]).to eq("fed:#{peer.id}")
    end
  end

  describe ".absorb_response! (caller side)" do
    it "trusts the accepter's CA, sets inbound_subject, and self-issues our cert" do
      described_class.absorb_response!(
        peer: peer,
        ca_bundle_pem: peer_ca_pem,
        assigned_inbound_subject: "fed:accepter-assigned-abc"
      )
      peer.reload
      expect(peer.trusted_ca_pem).to eq(peer_ca_pem)
      expect(peer.inbound_subject).to eq("fed:#{peer.id}")
      leaf = OpenSSL::X509::Certificate.new(peer.outbound_certificate.credentials["cert_pem"])
      expect(leaf.subject.to_s).to include("fed:accepter-assigned-abc")
    end
  end
end
