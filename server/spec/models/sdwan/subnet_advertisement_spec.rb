# frozen_string_literal: true

require "rails_helper"

# Sdwan::SubnetAdvertisement — focused on the 2026-05-19 addition of the
# pod_subnet source + scope, plus baseline source validation. Broader
# integration coverage of the row's role in the routing pipeline lives
# in spec/services/sdwan/bgp/config_compiler_spec.rb +
# spec/services/sdwan/topology_compiler_spec.rb.
RSpec.describe Sdwan::SubnetAdvertisement, type: :model do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  let!(:network) do
    Sdwan::Network.create!(account_id: account.id, name: "sub-ad-net-#{SecureRandom.hex(4)}")
  end

  let!(:node) { create(:system_node, account: account, name: "sub-ad-node-#{SecureRandom.hex(4)}") }
  let!(:instance) { create(:system_node_instance, node: node, name: "sub-ad-host-#{SecureRandom.hex(2)}") }
  let!(:peer) do
    Sdwan::PeerEnroller.call(network: network, node_instance: instance, publicly_reachable: false)
  end

  describe "SOURCES enum" do
    it "accepts the legacy three sources" do
      %w[declared_lan_subnet virtual_ip learned_via_bgp].each do |src|
        ad = described_class.new(
          peer: peer, network: network, account: account,
          prefix: "10.50.0.0/24", source: src
        )
        expect(ad).to be_valid, "expected source=#{src} to be valid"
      end
    end

    it "accepts the new pod_subnet source" do
      ad = described_class.new(
        peer: peer, network: network, account: account,
        prefix: "10.42.0.0/16", source: "pod_subnet"
      )
      expect(ad).to be_valid
    end

    it "rejects unknown sources" do
      ad = described_class.new(
        peer: peer, network: network, account: account,
        prefix: "10.42.0.0/16", source: "made_up_source"
      )
      expect(ad).not_to be_valid
      expect(ad.errors[:source]).to be_present
    end
  end

  describe "scopes" do
    before do
      described_class.create!(
        peer: peer, network: network, account: account,
        prefix: "10.50.0.0/24", source: "declared_lan_subnet"
      )
      described_class.create!(
        peer: peer, network: network, account: account,
        prefix: "10.42.0.0/16", source: "pod_subnet"
      )
    end

    it "pod_subnet scope returns only pod_subnet-sourced rows" do
      pod_ads = described_class.where(account: account).pod_subnet.pluck(:prefix, :source)
      expect(pod_ads).to contain_exactly(["10.42.0.0/16", "pod_subnet"])
    end

    it "declared scope still filters declared_lan_subnet only (unchanged)" do
      declared = described_class.where(account: account).declared.pluck(:source).uniq
      expect(declared).to eq(["declared_lan_subnet"])
    end
  end
end
