# frozen_string_literal: true

require "rails_helper"

# P9.4 — Federation::ResidencyEnforcer spec.
#
# Locks the per-pair residency decision logic + enforcement modes:
#
#   - same residency       → not crossed, allowed
#   - cross-boundary       → crossed; allowed only when mode != "refuse"
#   - either side unknown  → not crossed (don't enforce on undeclared)
RSpec.describe ::Federation::ResidencyEnforcer, type: :service do
  let(:account) { create(:account) }

  def make_peer(residency:)
    ::System::FederationPeer.create!(
      account: account,
      remote_instance_url: "https://peer-#{SecureRandom.hex(4)}.example.com",
      peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band",
      status: "active", data_residency: residency
    )
  end

  around do |example|
    saved_residency = ENV["POWERNODE_DATA_RESIDENCY"]
    saved_mode      = ENV["POWERNODE_RESIDENCY_ENFORCEMENT"]
    example.run
  ensure
    ENV["POWERNODE_DATA_RESIDENCY"]       = saved_residency
    ENV["POWERNODE_RESIDENCY_ENFORCEMENT"] = saved_mode
  end

  describe ".current_local_residency" do
    it "reads POWERNODE_DATA_RESIDENCY" do
      ENV["POWERNODE_DATA_RESIDENCY"] = "EU"
      expect(described_class.current_local_residency).to eq("EU")
    end

    it "falls back to unknown when env unset" do
      ENV.delete("POWERNODE_DATA_RESIDENCY")
      expect(described_class.current_local_residency).to eq("unknown")
    end
  end

  describe ".evaluate" do
    it "same residency → not crossed, allowed" do
      ENV["POWERNODE_DATA_RESIDENCY"] = "US"
      peer = make_peer(residency: "US")
      d = described_class.evaluate(remote_peer: peer)
      expect(d.crossed?).to be(false)
      expect(d.allowed).to be(true)
      expect(d.reason).to match(/same residency/)
    end

    it "cross-boundary in permissive mode → crossed but allowed" do
      ENV["POWERNODE_DATA_RESIDENCY"] = "US"
      ENV.delete("POWERNODE_RESIDENCY_ENFORCEMENT") # default = permissive
      peer = make_peer(residency: "EU")
      d = described_class.evaluate(remote_peer: peer)
      expect(d.crossed?).to be(true)
      expect(d.allowed).to be(true)
      expect(d.reason).to match(/cross-boundary/)
    end

    it "cross-boundary in refuse mode → crossed AND refused" do
      ENV["POWERNODE_DATA_RESIDENCY"] = "US"
      ENV["POWERNODE_RESIDENCY_ENFORCEMENT"] = "refuse"
      peer = make_peer(residency: "EU")
      d = described_class.evaluate(remote_peer: peer)
      expect(d.crossed?).to be(true)
      expect(d.allowed).to be(false)
      expect(d.refused?).to be(true)
    end

    it "local unknown → not crossed (can't enforce without declaration)" do
      ENV.delete("POWERNODE_DATA_RESIDENCY")
      peer = make_peer(residency: "EU")
      d = described_class.evaluate(remote_peer: peer)
      expect(d.crossed?).to be(false)
      expect(d.allowed).to be(true)
      expect(d.reason).to match(/not declared/)
    end

    it "remote unknown → not crossed" do
      ENV["POWERNODE_DATA_RESIDENCY"] = "US"
      peer = make_peer(residency: nil)
      d = described_class.evaluate(remote_peer: peer)
      expect(d.crossed?).to be(false)
      expect(d.allowed).to be(true)
      expect(d.reason).to match(/not declared/)
    end
  end
end
