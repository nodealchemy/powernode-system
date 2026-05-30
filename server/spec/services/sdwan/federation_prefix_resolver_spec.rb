# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::FederationPrefixResolver, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:other_account) { create(:account) }

  before do
    Sdwan::Network.where(account_id: account.id).delete_all
    System::FederationPeer.where(account_id: [ account.id, other_account.id ]).delete_all
  end

  let!(:network) do
    Sdwan::Network.create!(account_id: account.id, name: "fed-net-#{SecureRandom.hex(4)}")
  end

  # Helper — create a federation peer with a remote prefix advertisement.
  def fed_peer(prefix:, status:, peer_kind: "platform", account_for: account, **extra)
    attrs = {
      account: account_for,
      remote_instance_url: "https://peer-#{SecureRandom.hex(4)}.example.test",
      remote_prefix_advertisement: prefix,
      status: status,
      peer_kind: peer_kind
    }
    # platform peers require spawn_role; sdwan_only leave it nil.
    attrs[:spawn_role] = "symmetric" if peer_kind == "platform"
    System::FederationPeer.create!(attrs.merge(extra))
  end

  describe ".resolve" do
    it "returns structured entries for reachable platform peers carrying a prefix" do
      peer = fed_peer(prefix: "fd12:3456:789a::/48", status: "active")

      entries = described_class.resolve(network)
      expect(entries.size).to eq(1)
      entry = entries.first
      expect(entry[:federation_peer_id]).to eq(peer.id)
      expect(entry[:prefix]).to eq("fd12:3456:789a::/48")
      expect(entry[:status]).to eq("active")
      expect(entry[:peer_kind]).to eq("platform")
      expect(entry[:remote_instance_url]).to eq(peer.remote_instance_url)
    end

    it "includes enrolled and degraded platform peers (the reachable window)" do
      fed_peer(prefix: "fd00:1::/48", status: "enrolled")
      fed_peer(prefix: "fd00:2::/48", status: "degraded")

      prefixes = described_class.resolve(network).map { |e| e[:prefix] }
      expect(prefixes).to contain_exactly("fd00:1::/48", "fd00:2::/48")
    end

    it "EXCLUDES proposed platform peers (no live data-plane intent yet)" do
      fed_peer(prefix: "fd00:dead::/48", status: "proposed")
      expect(described_class.resolve(network)).to be_empty
    end

    it "EXCLUDES suspended and revoked platform peers (must not leak prefixes)" do
      fed_peer(prefix: "fd00:5054::/48", status: "active").suspend!(reason: "maint")
      revoked = fed_peer(prefix: "fd00:7e40::/48", status: "active")
      revoked.revoke!(reason: "decommissioned")

      expect(described_class.resolve(network)).to be_empty
    end

    it "includes accepted sdwan_only peers (their whole purpose is prefix advertisement)" do
      fed_peer(prefix: "fd00:5d00::/56", status: "accepted", peer_kind: "sdwan_only")

      prefixes = described_class.resolve(network).map { |e| e[:prefix] }
      expect(prefixes).to eq([ "fd00:5d00::/56" ])
    end

    it "EXCLUDES proposed sdwan_only peers" do
      fed_peer(prefix: "fd00:aaaa::/56", status: "proposed", peer_kind: "sdwan_only")
      expect(described_class.resolve(network)).to be_empty
    end

    it "is account-scoped — peers in another account never contribute" do
      fed_peer(prefix: "fd00:beef::/48", status: "active", account_for: other_account)
      expect(described_class.resolve(network)).to be_empty
    end

    it "skips peers with a blank prefix advertisement" do
      # remote_prefix_advertisement allows blank — a platform peer that
      # hasn't declared a prefix yet must not produce an entry.
      System::FederationPeer.create!(
        account: account, status: "active", peer_kind: "platform",
        spawn_role: "symmetric", remote_prefix_advertisement: nil,
        remote_instance_url: "https://peer-#{SecureRandom.hex(4)}.example.test"
      )
      expect(described_class.resolve(network)).to be_empty
    end

    it "de-duplicates by prefix when two peers advertise the same CIDR" do
      fed_peer(prefix: "fd00:d00d::/48", status: "active")
      fed_peer(prefix: "fd00:d00d::/48", status: "enrolled")

      entries = described_class.resolve(network)
      expect(entries.map { |e| e[:prefix] }).to eq([ "fd00:d00d::/48" ])
    end

    it "returns entries sorted by prefix for byte-stable output" do
      fed_peer(prefix: "fd00:cccc::/48", status: "active")
      fed_peer(prefix: "fd00:aaaa::/48", status: "active")
      fed_peer(prefix: "fd00:bbbb::/48", status: "active")

      prefixes = described_class.resolve(network).map { |e| e[:prefix] }
      expect(prefixes).to eq([ "fd00:aaaa::/48", "fd00:bbbb::/48", "fd00:cccc::/48" ])
    end

    it "returns [] for an un-persisted network (dry-run preview, no account_id)" do
      transient = Sdwan::Network.new(name: "transient")
      expect(described_class.resolve(transient)).to eq([])
    end

    it "selects exactly the peers the model's federation_prefix_contributing scope yields" do
      # Drift guard: the resolver MUST delegate liveness selection to the
      # model scope (composed from reachable/live) — not re-derive statuses.
      # Spread several statuses across both kinds, then assert the resolver's
      # account-scoped result matches the model scope intersected with the
      # account + a present prefix.
      fed_peer(prefix: "fd00:0a01::/48", status: "active")                             # platform reachable
      fed_peer(prefix: "fd00:0a02::/48", status: "proposed")                           # platform excluded
      fed_peer(prefix: "fd00:5001::/56", status: "accepted", peer_kind: "sdwan_only")  # sdwan_only live
      fed_peer(prefix: "fd00:5002::/56", status: "proposed", peer_kind: "sdwan_only")  # sdwan_only excluded

      expected = System::FederationPeer
        .federation_prefix_contributing
        .where(account_id: account.id)
        .where.not(remote_prefix_advertisement: [ nil, "" ])
        .map(&:remote_prefix_advertisement)
        .sort

      expect(described_class.prefixes_for(network)).to eq(expected)
    end
  end

  describe ".prefixes_for" do
    it "returns just the de-duplicated prefix strings" do
      fed_peer(prefix: "fd00:1::/48", status: "active")
      fed_peer(prefix: "fd00:2::/64", status: "enrolled")

      expect(described_class.prefixes_for(network)).to eq([ "fd00:1::/48", "fd00:2::/64" ])
    end

    it "returns [] when no federation peers contribute" do
      expect(described_class.prefixes_for(network)).to eq([])
    end
  end
end
