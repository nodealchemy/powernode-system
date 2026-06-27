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

    it "fails closed (MATCH_NOTHING) for a tag that resolves to no peers" do
      # No peer-tag write path yet → the tag matches nobody → the rule must
      # restrict to nothing, NOT silently become a wildcard (fail-open).
      expect(described_class.to_nft_match({ "tag" => "production" }, side: :saddr))
        .to eq(described_class::MATCH_NOTHING)
    end

    it "compiles a tag selector into an nft set of the tagged peers' addresses" do
      allow(described_class).to receive(:addresses_for_tag)
        .with("production", network: nil)
        .and_return([ "fd00:1::5", "fd00:1::9" ])

      expect(described_class.to_nft_match({ "tag" => "production" }, side: :saddr))
        .to eq("ip6 saddr { fd00:1::5, fd00:1::9 }")
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
      let(:node) { create(:system_node, account: account, name: "sel-node-#{SecureRandom.hex(4)}") }
      let(:instance) { create(:system_node_instance, node: node, name: "sel-inst-#{SecureRandom.hex(2)}") }

      it "compiles a peer_id selector to that peer's /128 address" do
        peer = Sdwan::PeerEnroller.call(network: network, node_instance: instance)
        clause = described_class.to_nft_match({ "peer_id" => peer.id }, side: :saddr)
        expect(clause).to eq("ip6 saddr #{peer.assigned_address}")
      end

      it "fails closed (MATCH_NOTHING) for a peer_id pointing at a deleted peer" do
        clause = described_class.to_nft_match({ "peer_id" => SecureRandom.uuid }, side: :saddr)
        expect(clause).to eq(described_class::MATCH_NOTHING)
      end
    end

    context "with a tag selector resolving real tagged peers (D8 write path)" do
      let(:account) { Account.first || create(:account) }
      let(:network) do
        Sdwan::Configuration.where(account_id: account.id).delete_all
        Sdwan::Network.where(account_id: account.id).delete_all
        Sdwan::Network.create!(account_id: account.id, name: "tag-net-#{SecureRandom.hex(4)}")
      end
      let(:node) { create(:system_node, account: account, name: "tag-node-#{SecureRandom.hex(4)}") }

      def enroll_peer(tags)
        inst = create(:system_node_instance, node: node, name: "tag-inst-#{SecureRandom.hex(3)}")
        peer = Sdwan::PeerEnroller.call(network: network, node_instance: inst)
        peer.update!(tags: tags)
        peer
      end

      it "compiles to an nft set of the addresses of peers carrying the tag" do
        db1 = enroll_peer(%w[database])
        db2 = enroll_peer(%w[database edge])
        enroll_peer(%w[web]) # unrelated — must NOT appear

        clause = described_class.to_nft_match({ "tag" => "database" }, side: :saddr, network: network)
        expect(clause).to start_with("ip6 saddr { ")
        expect(clause).to include(db1.assigned_address)
        expect(clause).to include(db2.assigned_address)
      end

      it "fails closed (MATCH_NOTHING) for a tag no peer carries" do
        enroll_peer(%w[web])
        expect(described_class.to_nft_match({ "tag" => "nonexistent" }, side: :saddr, network: network))
          .to eq(described_class::MATCH_NOTHING)
      end
    end
  end
end
