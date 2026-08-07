# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::SdwanDriftSensor do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account, status: "active") }
  let(:sensor)  { described_class.new(account: account) }

  describe "#sense" do
    it "emits a system.sdwan_peer_drift signal for a peer whose handshake is stale" do
      peer = create(:sdwan_peer, account: account, network: network, last_handshake_at: 10.minutes.ago)

      sig = sensor.sense.find { |s| s.kind == "system.sdwan_peer_drift" }

      expect(sig).not_to be_nil
      expect(sig.kind).to eq("system.sdwan_peer_drift")
      expect(sig.severity).to eq(:medium)
      expect(sig.payload["peer_id"]).to eq(peer.id)
      expect(sig.payload["remediation_action"]).to eq("system.sdwan_peer_remediate")
    end

    # A peer that has never handshaked has no handshake_age to measure — the
    # sensor's own `last_handshake_at IS NOT NULL` guard skips it rather than
    # treating the absence as an infinite (or zero) age.
    it "does not emit for a peer that has never handshaked" do
      create(:sdwan_peer, account: account, network: network, last_handshake_at: nil)

      expect(sensor.sense).to be_empty
    end
  end

  it "binds system.sdwan_peer_drift to the sdwan_peer_remediate gate in SIGNAL_BINDINGS" do
    binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.sdwan_peer_drift"]

    expect(binding).to be_present
    expect(binding[:action_category]).to eq("system.sdwan_peer_remediate")
  end
end
