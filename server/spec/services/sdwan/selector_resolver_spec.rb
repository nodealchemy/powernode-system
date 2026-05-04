# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::SelectorResolver, type: :service do
  describe ".to_nft_match" do
    it "returns nil for blank selector" do
      expect(described_class.to_nft_match({},  side: :saddr)).to be_nil
      expect(described_class.to_nft_match(nil, side: :saddr)).to be_nil
    end

    it "returns nil for the wildcard `all` selector" do
      expect(described_class.to_nft_match({ "all" => true }, side: :saddr)).to be_nil
      expect(described_class.to_nft_match({ all: true },     side: :daddr)).to be_nil
    end

    it "compiles a cidr selector into the corresponding ip6 clause" do
      expect(described_class.to_nft_match({ "cidr" => "fd00:1::/64" }, side: :saddr))
        .to eq("ip6 saddr fd00:1::/64")
      expect(described_class.to_nft_match({ "cidr" => "fd00:2::/96" }, side: :daddr))
        .to eq("ip6 daddr fd00:2::/96")
    end

    it "returns nil for a tag selector (slice 5 will populate sets)" do
      expect(described_class.to_nft_match({ "tag" => "production" }, side: :saddr)).to be_nil
    end

    it "raises on an unknown side" do
      expect {
        described_class.to_nft_match({ "cidr" => "fd00::/64" }, side: :input)
      }.to raise_error(ArgumentError, /side must be :saddr or :daddr/)
    end

    context "with a peer_id selector" do
      let(:account) { Account.first || create(:account) }
      let(:network) do
        Sdwan::Configuration.where(account_id: account.id).delete_all
        Sdwan::Network.where(account_id: account.id).delete_all
        Sdwan::Network.create!(account_id: account.id, name: "sel-net-#{SecureRandom.hex(4)}")
      end
      let(:node) { ::System::Node.create!(account: account, name: "sel-node-#{SecureRandom.hex(4)}") }
      let(:instance) { ::System::NodeInstance.create!(node: node, name: "sel-inst-#{SecureRandom.hex(2)}") }

      it "compiles a peer_id selector to that peer's /128 address" do
        peer = Sdwan::PeerEnroller.call(network: network, node_instance: instance)
        clause = described_class.to_nft_match({ "peer_id" => peer.id }, side: :saddr)
        expect(clause).to eq("ip6 saddr #{peer.assigned_address}")
      end

      it "returns nil for a peer_id pointing at a deleted peer" do
        clause = described_class.to_nft_match({ "peer_id" => SecureRandom.uuid }, side: :saddr)
        expect(clause).to be_nil
      end
    end
  end
end
