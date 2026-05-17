# frozen_string_literal: true

require "rails_helper"

# Covers the P3.6 additions to Sdwan::FederationGovernance#scan:
# peer_heartbeat_stale, peer_capability_drift, peer_cert_expiring,
# peer_cert_expired. The original v1 findings (prefix_overlap, etc.) are
# exercised elsewhere.
RSpec.describe Sdwan::FederationGovernance, type: :service do
  let(:account) { create(:account) }

  describe "peer_heartbeat_stale" do
    it "flags active platform peers with no heartbeat" do
      create(:system_federation_peer, :active,
             account: account, last_heartbeat_at: nil)
      findings = described_class.scan(account: account)
      kinds = findings.map { |f| f[:kind] }
      expect(kinds).to include(:peer_heartbeat_stale)
    end

    it "flags enrolled peers whose last heartbeat is too old" do
      create(:system_federation_peer, :enrolled,
             account: account, last_heartbeat_at: 10.minutes.ago)
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).to include(:peer_heartbeat_stale)
    end

    it "does NOT flag sdwan_only peers regardless of heartbeat" do
      create(:system_federation_peer,
             account: account, peer_kind: "sdwan_only",
             status: "accepted", last_heartbeat_at: nil)
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).not_to include(:peer_heartbeat_stale)
    end

    it "does NOT flag fresh active platform peers" do
      create(:system_federation_peer, :active,
             account: account, last_heartbeat_at: 30.seconds.ago)
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).not_to include(:peer_heartbeat_stale)
    end
  end

  describe "peer_capability_drift" do
    it "flags peers that advertise extensions but have no capabilities" do
      create(:system_federation_peer, :active,
             account: account,
             extension_slugs: [ "trading" ],
             capabilities: {})
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).to include(:peer_capability_drift)
    end

    it "does NOT flag peers with matching extensions + capabilities" do
      create(:system_federation_peer, :active,
             account: account,
             extension_slugs: [ "trading" ],
             capabilities: { "trading_strategy" => { "read" => true } })
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).not_to include(:peer_capability_drift)
    end
  end

  describe "peer_cert_expiring + peer_cert_expired" do
    let(:peer) { create(:system_federation_peer, :active, account: account) }

    def attach_cert!(not_after:)
      cert = ::System::NodeCertificate.create!(
        account: account,
        subject_kind: "federation_peer",
        subject: "peer-cert-#{SecureRandom.uuid}",
        serial: SecureRandom.hex(16),
        not_before: 365.days.ago,  # safely before any test not_after
        not_after: not_after,
        pem_chain: "stub",
        issuer_subject: "Powernode Internal CA"
      )
      peer.update!(node_certificate: cert)
    end

    it "flags peer_cert_expiring when cert is within 30 days of expiry" do
      attach_cert!(not_after: 20.days.from_now)
      findings = described_class.scan(account: account)
      kinds = findings.map { |f| f[:kind] }
      expect(kinds).to include(:peer_cert_expiring)
      expect(kinds).not_to include(:peer_cert_expired)
    end

    it "flags peer_cert_expired when cert is past not_after" do
      attach_cert!(not_after: 1.day.ago)
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).to include(:peer_cert_expired)
    end

    it "does NOT flag healthy long-lived certs" do
      attach_cert!(not_after: 120.days.from_now)
      findings = described_class.scan(account: account)
      kinds = findings.map { |f| f[:kind] }
      expect(kinds).not_to include(:peer_cert_expiring)
      expect(kinds).not_to include(:peer_cert_expired)
    end
  end

  describe "severity assignment" do
    it "assigns the right severity to each new finding kind" do
      expect(described_class::SEVERITY_BY_KIND[:peer_heartbeat_stale]).to eq(:medium)
      expect(described_class::SEVERITY_BY_KIND[:peer_capability_drift]).to eq(:medium)
      expect(described_class::SEVERITY_BY_KIND[:peer_cert_expiring]).to eq(:medium)
      expect(described_class::SEVERITY_BY_KIND[:peer_cert_expired]).to eq(:high)
    end
  end
end
