# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::PrefixAllocator, type: :service do
  describe ".generate_random_prefix_40" do
    it "produces a /40 ULA prefix in fdXX:XXXX:XX00::/40 form" do
      10.times do
        prefix = described_class.generate_random_prefix_40
        expect(prefix).to match(%r{\Afd[0-9a-f]{2}:[0-9a-f]{4}:[0-9a-f]{2}00::/40\z})
      end
    end

    it "always sets the leading byte to fd (locally-assigned ULA range)" do
      100.times do
        expect(described_class.generate_random_prefix_40).to start_with("fd")
      end
    end
  end

  describe ".compose_prefix_48" do
    it "fills the lower 8 bits of group 3 with the account byte" do
      expect(described_class.compose_prefix_48("fd12:34ab:cd00::/40", 0x42))
        .to eq("fd12:34ab:cd42::/48")
    end

    it "preserves the install /40 root unchanged in the resulting /48" do
      result = described_class.compose_prefix_48("fdaa:bbbb:cc00::/40", 0xff)
      expect(result).to eq("fdaa:bbbb:ccff::/48")
    end

    it "round-trips with extract_account_byte" do
      prefix_48 = described_class.compose_prefix_48("fd12:34ab:cd00::/40", 0x9c)
      expect(described_class.extract_account_byte(prefix_48)).to eq(0x9c)
    end
  end

  describe ".compose_cidr_64" do
    it "appends the 16-bit network word to the account /48" do
      expect(described_class.compose_cidr_64("fd12:34ab:cd42::/48", 0x9876))
        .to eq("fd12:34ab:cd42:9876::/64")
    end
  end

  describe ".compose_address_128" do
    it "appends 64 host bits as 4 colon-separated 16-bit groups" do
      host64 = [0x1234, 0x5678, 0x9abc, 0xdef0].pack("nnnn")
      expect(described_class.compose_address_128("fd12:34ab:cd42:9876::/64", host64))
        .to eq("fd12:34ab:cd42:9876:1234:5678:9abc:def0/128")
    end
  end

  describe ".account_byte_from_seed" do
    it "returns a deterministic byte for the same seed" do
      uuid = "11111111-1111-1111-1111-111111111111"
      expect(described_class.account_byte_from_seed(uuid))
        .to eq(described_class.account_byte_from_seed(uuid))
    end

    it "returns a value in 0..255" do
      100.times do |i|
        byte = described_class.account_byte_from_seed("seed-#{i}")
        expect(byte).to be_between(0, 255)
      end
    end

    it "produces different bytes for different seeds (most of the time)" do
      bytes = (1..50).map { |i| described_class.account_byte_from_seed("seed-#{i}") }
      expect(bytes.uniq.size).to be > 30 # birthday-paradox bound
    end
  end

  describe ".network_word_from_seed" do
    it "returns a deterministic word in 0..65535" do
      uuid = "22222222-2222-2222-2222-222222222222"
      word = described_class.network_word_from_seed(uuid)
      expect(word).to eq(described_class.network_word_from_seed(uuid))
      expect(word).to be_between(0, 65_535)
    end
  end

  describe ".peer_host_64bits_from_seed" do
    it "returns 8 bytes deterministically from the same seed" do
      uuid = "33333333-3333-3333-3333-333333333333"
      bytes = described_class.peer_host_64bits_from_seed(uuid)
      expect(bytes.bytesize).to eq(8)
      expect(bytes).to eq(described_class.peer_host_64bits_from_seed(uuid))
    end

    it "produces different host bits for different peer ids" do
      bytes_a = described_class.peer_host_64bits_from_seed("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
      bytes_b = described_class.peer_host_64bits_from_seed("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
      expect(bytes_a).not_to eq(bytes_b)
    end
  end

  describe "DB-backed allocation", :db do
    let(:account) { Account.first || create(:account) }

    describe ".ensure_configuration!" do
      it "creates a row on first call" do
        Sdwan::Configuration.where(account_id: account.id).delete_all
        cfg = described_class.ensure_configuration!(account_id: account.id)
        expect(cfg.instance_prefix_40).to match(%r{\Afd[0-9a-f]{2}:[0-9a-f]{4}:[0-9a-f]{2}00::/40\z})
        expect(cfg.account_prefix_48).to match(%r{\Afd[0-9a-f]{2}:[0-9a-f]{4}:[0-9a-f]{2}[0-9a-f]{2}::/48\z})
      end

      it "is idempotent across calls for the same account" do
        cfg_a = described_class.ensure_configuration!(account_id: account.id)
        cfg_b = described_class.ensure_configuration!(account_id: account.id)
        expect(cfg_a.id).to eq(cfg_b.id)
        expect(cfg_a.account_prefix_48).to eq(cfg_b.account_prefix_48)
      end

      it "shares the install /40 root across multiple accounts" do
        cfg_a = described_class.ensure_configuration!(account_id: account.id)
        other = create(:account)
        cfg_b = described_class.ensure_configuration!(account_id: other.id)
        expect(cfg_a.instance_prefix_40).to eq(cfg_b.instance_prefix_40)
        expect(cfg_a.account_prefix_48).not_to eq(cfg_b.account_prefix_48)
      end
    end

    describe ".allocate_network_cidr!" do
      it "produces a /64 within the account's /48" do
        cfg = described_class.ensure_configuration!(account_id: account.id)
        cidr = described_class.allocate_network_cidr!(account_id: account.id, network_id: UUID7.generate)
        expect(cidr).to start_with(cfg.account_prefix_48.sub(%r{::/48\z}, ""))
        expect(cidr).to end_with("::/64")
      end
    end

    describe ".allocate_peer_address!" do
      it "fills 64 host bits within the network's /64" do
        Sdwan::Configuration.where(account_id: account.id).delete_all
        Sdwan::Network.where(account_id: account.id).delete_all
        network = Sdwan::Network.create!(account_id: account.id, name: "test-net-#{SecureRandom.hex(4)}")
        addr = described_class.allocate_peer_address!(network: network, peer_id: UUID7.generate)
        expect(addr).to start_with(network.cidr_64.sub(%r{::/64\z}, ":"))
        expect(addr).to end_with("/128")
      end

      it "is deterministic for the same peer_id" do
        Sdwan::Configuration.where(account_id: account.id).delete_all
        Sdwan::Network.where(account_id: account.id).delete_all
        network = Sdwan::Network.create!(account_id: account.id, name: "test-net-#{SecureRandom.hex(4)}")
        peer_id = UUID7.generate
        a = described_class.allocate_peer_address!(network: network, peer_id: peer_id)
        b = described_class.allocate_peer_address!(network: network, peer_id: peer_id)
        expect(a).to eq(b)
      end
    end
  end
end
