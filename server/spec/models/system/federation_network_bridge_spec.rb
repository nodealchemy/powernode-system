# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::FederationNetworkBridge, type: :model do
  describe "constants" do
    it "defines STATES + TRANSITIONS" do
      expect(described_class::STATES).to eq(%w[proposed active suspended revoked])
      expect(described_class::TRANSITIONS["proposed"]).to eq(%w[active revoked])
      expect(described_class::TRANSITIONS["active"]).to eq(%w[suspended revoked])
      expect(described_class::TRANSITIONS["revoked"]).to eq([])
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:federation_peer).class_name("System::FederationPeer") }
    it { is_expected.to belong_to(:sdwan_network).class_name("Sdwan::Network") }
  end

  describe "validations" do
    subject { build(:system_federation_network_bridge) }

    it { is_expected.to validate_inclusion_of(:state).in_array(described_class::STATES) }

    it "enforces uniqueness on (peer, network)" do
      first = create(:system_federation_network_bridge)
      dup = build(:system_federation_network_bridge,
                  federation_peer: first.federation_peer,
                  sdwan_network: first.sdwan_network,
                  account: first.account)
      expect(dup).not_to be_valid
    end
  end

  describe "lifecycle" do
    it "stamps proposed_at on create" do
      bridge = create(:system_federation_network_bridge)
      expect(bridge.proposed_at).to be_within(2.seconds).of(Time.current)
    end

    it "#activate! transitions proposed → active with timestamp" do
      bridge = create(:system_federation_network_bridge)
      bridge.activate!
      expect(bridge.reload.state).to eq("active")
      expect(bridge.activated_at).to be_within(2.seconds).of(Time.current)
    end

    it "#suspend! transitions active → suspended with reason" do
      bridge = create(:system_federation_network_bridge, :active)
      bridge.suspend!(reason: "operator pause")
      expect(bridge.reload.state).to eq("suspended")
      expect(bridge.suspended_at).to be_within(2.seconds).of(Time.current)
      expect(bridge.metadata["suspension_reason"]).to eq("operator pause")
    end

    it "#revoke! transitions any non-terminal → revoked" do
      bridge = create(:system_federation_network_bridge, :active)
      bridge.revoke!(reason: "no longer needed")
      expect(bridge.reload.state).to eq("revoked")
      expect(bridge.revoked_at).to be_within(2.seconds).of(Time.current)
      expect(bridge.revocation_reason).to eq("no longer needed")
    end

    it "rejects revoked → active transitions" do
      bridge = create(:system_federation_network_bridge)
      bridge.revoke!
      expect(bridge.activate!).to be false
      expect(bridge.reload.state).to eq("revoked")
    end
  end

  describe "scopes" do
    let!(:proposed) { create(:system_federation_network_bridge) }
    let!(:active_b) { create(:system_federation_network_bridge, :active) }
    let!(:suspended) { create(:system_federation_network_bridge, :suspended) }

    it ".live includes proposed + active" do
      expect(described_class.live).to include(proposed, active_b)
      expect(described_class.live).not_to include(suspended)
    end

    it ".active filters by state" do
      expect(described_class.active).to eq([ active_b ])
    end
  end
end
