# frozen_string_literal: true

require "rails_helper"

# Phase 3c — federation liveness sensor.
RSpec.describe System::Fleet::Sensors::FederationPeerLivenessSensor do
  let(:account) { create(:account) }
  let(:sensor)  { described_class.new(account: account) }

  before do
    System::FederationPeer.where(account_id: account.id).delete_all
  end

  # Builds a federation node_certificate (subject_kind="federation_peer")
  # with the given validity window, matching the FederationManager spec's
  # direct-create pattern (no factory trait for federation_peer cert kind).
  def federation_cert(not_before:, not_after:)
    ::System::NodeCertificate.create!(
      account: account,
      subject_kind: "federation_peer",
      subject: "peer-#{SecureRandom.uuid}",
      serial: SecureRandom.hex(16),
      not_before: not_before,
      not_after: not_after,
      pem_chain: "stub",
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  describe "#sense" do
    it "emits nothing on an account with no federation peers" do
      expect(sensor.sense).to eq([])
    end

    it "ignores a healthy active peer that heartbeated recently" do
      create(:system_federation_peer, :active, account: account,
                                               last_heartbeat_at: 30.seconds.ago)
      expect(sensor.sense).to be_empty
    end

    it "ignores sdwan_only peers entirely (heartbeat_stale scope is platform-only)" do
      create(:system_federation_peer, account: account,
                                      peer_kind: "sdwan_only", status: "accepted")
      expect(sensor.sense).to be_empty
    end

    context "heartbeat staleness" do
      it "emits a high-severity signal for a stale ACTIVE peer" do
        peer = create(:system_federation_peer, :active, account: account,
                                                        last_heartbeat_at: 10.minutes.ago)
        sig = sensor.sense.find { |s| s.payload["federation_peer_id"] == peer.id }

        expect(sig).not_to be_nil
        expect(sig.kind).to eq("system.federation_peer_liveness")
        expect(sig.severity).to eq(:high)
        expect(sig.payload["reason"]).to eq("heartbeat_stale")
        expect(sig.payload["peer_status"]).to eq("active")
        expect(sig.payload["remediation_action"]).to eq("system.federation_peer_remediate")
      end

      it "emits a medium-severity signal for a stale ENROLLED peer (never came up)" do
        peer = create(:system_federation_peer, :enrolled, account: account,
                                                          last_heartbeat_at: nil)
        sig = sensor.sense.find { |s| s.payload["federation_peer_id"] == peer.id }

        expect(sig).not_to be_nil
        expect(sig.severity).to eq(:medium)
        expect(sig.payload["reason"]).to eq("heartbeat_stale")
      end

      it "uses a stable per-peer heartbeat fingerprint within a staleness window" do
        last_hb = 12.minutes.ago
        peer = create(:system_federation_peer, :active, account: account,
                                                        last_heartbeat_at: last_hb)
        first  = sensor.sense.find { |s| s.payload["federation_peer_id"] == peer.id }
        second = described_class.new(account: account).sense
                               .find { |s| s.payload["federation_peer_id"] == peer.id }

        expect(first.fingerprint).to eq(second.fingerprint)
        expect(first.fingerprint).to start_with("federation_peer_liveness:heartbeat_stale:#{peer.id}:")
      end

      it "collapses a never-heartbeated peer to a stable 'never' fingerprint bucket" do
        peer = create(:system_federation_peer, :enrolled, account: account, last_heartbeat_at: nil)
        sig = sensor.sense.find { |s| s.payload["federation_peer_id"] == peer.id }
        expect(sig.fingerprint).to eq("federation_peer_liveness:heartbeat_stale:#{peer.id}:never")
      end
    end

    context "cert expiry (via FederationGovernance)" do
      it "emits a medium-severity cert_expiring signal for a peer cert near not_after" do
        cert = federation_cert(not_before: 60.days.ago, not_after: 10.days.from_now)
        peer = create(:system_federation_peer, :active, account: account,
                                                        node_certificate: cert,
                                                        last_heartbeat_at: 30.seconds.ago)

        sig = sensor.sense.find do |s|
          s.payload["federation_peer_id"] == peer.id && s.payload["reason"] == "cert_expiring"
        end
        expect(sig).not_to be_nil
        expect(sig.kind).to eq("system.federation_peer_liveness")
        expect(sig.severity).to eq(:medium)
        expect(sig.fingerprint).to eq("federation_peer_liveness:cert_expiring:#{peer.id}")
      end

      it "emits a high-severity cert_expired signal for an already-expired peer cert" do
        cert = federation_cert(not_before: 100.days.ago, not_after: 2.days.ago)
        peer = create(:system_federation_peer, :active, account: account,
                                                        node_certificate: cert,
                                                        last_heartbeat_at: 30.seconds.ago)

        sig = sensor.sense.find do |s|
          s.payload["federation_peer_id"] == peer.id && s.payload["reason"] == "cert_expired"
        end
        expect(sig).not_to be_nil
        expect(sig.severity).to eq(:high)
        expect(sig.fingerprint).to eq("federation_peer_liveness:cert_expired:#{peer.id}")
      end

      it "does NOT emit a cert signal for a healthy long-lived cert" do
        cert = federation_cert(not_before: 1.day.ago, not_after: 180.days.from_now)
        peer = create(:system_federation_peer, :active, account: account,
                                                        node_certificate: cert,
                                                        last_heartbeat_at: 30.seconds.ago)
        cert_sigs = sensor.sense.select do |s|
          s.payload["federation_peer_id"] == peer.id &&
            %w[cert_expiring cert_expired].include?(s.payload["reason"])
        end
        expect(cert_sigs).to be_empty
      end

      it "survives a cert query failure without dropping heartbeat signals" do
        peer = create(:system_federation_peer, :active, account: account,
                                                        last_heartbeat_at: 10.minutes.ago)
        # Force only the direct cert query to blow up (it's the sole path
        # that joins node_certificate); heartbeat signals — a separate
        # query — must still surface, proving the cert rescue is scoped.
        allow_any_instance_of(::ActiveRecord::Relation)
          .to receive(:joins).with(:node_certificate).and_raise(StandardError, "boom")

        signals = sensor.sense
        expect(signals.map { |s| s.payload["federation_peer_id"] }).to include(peer.id)
      end
    end

    it "scopes to the current account" do
      other = create(:account)
      create(:system_federation_peer, :active, account: other, last_heartbeat_at: 10.minutes.ago)
      expect(sensor.sense).to be_empty
    end

    it "is purely read-side — never mutates peer state" do
      peer = create(:system_federation_peer, :active, account: account,
                                                      last_heartbeat_at: 10.minutes.ago)
      expect { sensor.sense }.not_to change { peer.reload.status }
      expect(peer.reload.status).to eq("active")
    end

    it "emits valid Signal value objects" do
      create(:system_federation_peer, :active, account: account, last_heartbeat_at: 10.minutes.ago)
      sensor.sense.each do |sig|
        expect(sig).to be_a(::System::Fleet::Signal)
        expect(System::Fleet::Signal::VALID_SEVERITIES).to include(sig.severity)
        expect(sig.fingerprint).to be_present
      end
    end
  end
end
