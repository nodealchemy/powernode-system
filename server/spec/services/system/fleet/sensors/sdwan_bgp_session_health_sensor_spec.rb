# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::SdwanBgpSessionHealthSensor do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:peer)    { create(:sdwan_peer, account: account, network: network) }
  let(:sensor)  { described_class.new(account: account) }

  def make_session(state:, last_state_change_at:, last_observed_at:, neighbor_address: "fd00:abcd:9::1")
    Sdwan::BgpSession.create!(
      peer: peer,
      network: network,
      neighbor_address: neighbor_address,
      state: state,
      last_state_change_at: last_state_change_at,
      last_observed_at: last_observed_at
    )
  end

  describe "#sense" do
    it "emits a system.sdwan_bgp_session_unhealthy signal for a session stuck off established" do
      session = make_session(state: "active", last_state_change_at: 10.minutes.ago, last_observed_at: 1.minute.ago)

      sig = sensor.sense.find { |s| s.kind == "system.sdwan_bgp_session_unhealthy" }

      expect(sig).not_to be_nil
      expect(sig.kind).to eq("system.sdwan_bgp_session_unhealthy")
      expect(sig.severity).to eq(:medium)
      expect(sig.payload["bgp_session_id"]).to eq(session.id)
      expect(sig.payload["remediation_action"]).to eq("system.sdwan_bgp_session_remediate")
    end

    it "emits a system.sdwan_bgp_session_stale signal for a session with no recent observation" do
      session = make_session(state: "idle", last_state_change_at: 20.minutes.ago, last_observed_at: 10.minutes.ago)

      sig = sensor.sense.find { |s| s.kind == "system.sdwan_bgp_session_stale" }

      expect(sig).not_to be_nil
      expect(sig.kind).to eq("system.sdwan_bgp_session_stale")
      expect(sig.severity).to eq(:medium)
      expect(sig.payload["bgp_session_id"]).to eq(session.id)
    end

    it "returns no signals for a healthy, recently-observed session" do
      make_session(state: "established", last_state_change_at: 1.minute.ago, last_observed_at: 1.minute.ago)

      expect(sensor.sense).to be_empty
    end
  end

  it "registers both emitted kinds in the DecisionEngine's SIGNAL_BINDINGS" do
    unhealthy = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.sdwan_bgp_session_unhealthy"]
    stale = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.sdwan_bgp_session_stale"]

    expect(unhealthy).to be_present
    expect(unhealthy[:action_category]).to eq("system.sdwan_bgp_session_remediate")
    expect(stale).to be_present
  end
end
