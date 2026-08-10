# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::SdwanReachabilitySensor do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account, status: "active") }
  let(:sensor)  { described_class.new(account: account) }

  describe "#sense" do
    it "emits a system.sdwan_hub_unreachable signal when no peer has a recent handshake" do
      create(:sdwan_peer, :hub, account: account, network: network, last_handshake_at: nil)

      sig = sensor.sense.find { |s| s.kind == "system.sdwan_hub_unreachable" }

      expect(sig).not_to be_nil
      expect(sig.kind).to eq("system.sdwan_hub_unreachable")
      expect(sig.severity).to eq(:critical) # single hub, no backup to fail over to
      expect(sig.payload["network_id"]).to eq(network.id)
      expect(sig.payload["remediation_action"]).to eq("system.sdwan_failover")
      expect(sig.payload["hub_count"]).to eq(1)
    end

    it "returns no signal when a peer has a recent handshake (network is functionally up)" do
      create(:sdwan_peer, :hub, account: account, network: network, last_handshake_at: 1.minute.ago)

      expect(sensor.sense).to be_empty
    end

    # IMP-07217a21eaba — the old skip claimed "compiler will warn" about a
    # no-hub network; no such warning exists (only generated user-device
    # configs embed a comment nobody may ever read). An active hub-and-spoke
    # network with zero hubs cannot form tunnels and previously produced NO
    # signal from any fleet sensor.
    it "signals an active hub-and-spoke network with no hub configured" do
      create(:sdwan_peer, account: account, network: network, publicly_reachable: false, last_handshake_at: nil)

      sig = sensor.sense.find { |s| s.payload["no_hub_configured"] }

      expect(sig).not_to be_nil
      expect(sig.kind).to eq("system.sdwan_hub_unreachable") # reuses the bound, policied kind
      expect(sig.severity).to eq(:critical)
      expect(sig.payload["hub_count"]).to eq(0)
      expect(sig.fingerprint).to eq("sdwan_no_hub:#{network.id}") # dedupes separately from unreachable
    end

    it "signals no-hub regardless of recent spoke handshakes (a config gap, not a traffic one)" do
      create(:sdwan_peer, account: account, network: network, publicly_reachable: false,
             last_handshake_at: 1.minute.ago)

      expect(sensor.sense.find { |s| s.payload["no_hub_configured"] }).not_to be_nil
    end

    it "stays silent for a hubless full-mesh network (legitimately has no hubs)" do
      mesh = create(:sdwan_network, account: account, status: "active",
                    settings: { "topology_strategy" => "full_mesh" })
      create(:sdwan_peer, account: account, network: mesh, publicly_reachable: false, last_handshake_at: nil)

      expect(sensor.sense).to be_empty
    end
  end

  it "binds system.sdwan_hub_unreachable to the sdwan_failover gate in SIGNAL_BINDINGS" do
    binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.sdwan_hub_unreachable"]

    expect(binding).to be_present
    expect(binding[:action_category]).to eq("system.sdwan_failover")
  end
end
