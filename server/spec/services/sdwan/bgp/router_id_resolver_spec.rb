# frozen_string_literal: true

require "rails_helper"

# RouterIdResolver derives a deterministic 32-bit BGP router-id (rendered
# as an IPv4 dotted-quad) for each peer. Routing correctness depends on the
# id being a PURE function of the account's peer-set + overrides — never of
# resolution order — so iBGP path selection is stable across compiles.
#
# Decision D11 adds two behaviours on top of the historical derivation:
#   (1) same-account hash collisions auto-resolve via deterministic salt
#       perturbation (lowest-id peer keeps salt 0; others take the next
#       free salt), and
#   (2) accounts on router_id_strategy "explicit" warn (and fall back to
#       the derived id) when a peer has no override.
#
# The salt-0 derivation is byte-identical to the pre-D11 code, so
# non-colliding peers — and the BGP config golden fixtures — are unchanged.
RSpec.describe Sdwan::Bgp::RouterIdResolver, type: :service do
  # The exact pre-D11 derivation, reproduced here so the no-collision
  # example characterises salt-0 == today (guards against accidental drift).
  def legacy_derive(address)
    digest = Digest::SHA256.digest(address.to_s)
    u32 = digest.unpack1("N")
    a = (u32 >> 24) & 0xff
    b = (u32 >> 16) & 0xff
    c = (u32 >> 8) & 0xff
    d = u32 & 0xff
    a = 1 if a.zero?
    "#{a}.#{b}.#{c}.#{d}"
  end

  describe "no collision (behavior-preserving)" do
    it "returns exactly the historical SHA256-derived dotted-quad" do
      account = create(:account)
      network = create(:sdwan_network, account: account)
      peer = create(:sdwan_peer, account: account, network: network)

      expect(described_class.for_peer(peer)).to eq(legacy_derive(peer.assigned_address))
    end

    it "does not warn when no AccountBgp / default strategy is configured" do
      account = create(:account)
      network = create(:sdwan_network, account: account)
      peer = create(:sdwan_peer, account: account, network: network)
      create(:sdwan_account_bgp, account: account) # default "peer_overlay_ipv6_hash"

      allow(Rails.logger).to receive(:warn)
      described_class.for_peer(peer)
      expect(Rails.logger).not_to have_received(:warn).with(/router_id_strategy=explicit/)
    end
  end

  describe "operator override" do
    it "returns the override verbatim, unchanged" do
      account = create(:account)
      network = create(:sdwan_network, account: account)
      peer = create(:sdwan_peer, account: account, network: network,
                                 bgp_router_id_override: "203.0.113.7")

      expect(described_class.for_peer(peer)).to eq("203.0.113.7")
    end
  end

  describe "collision auto-resolve" do
    let(:account) { create(:account) }
    let(:network) { create(:sdwan_network, account: account) }
    let!(:peer_x) { create(:sdwan_peer, account: account, network: network) }
    let!(:peer_y) { create(:sdwan_peer, account: account, network: network) }

    # Lowest id keeps salt 0; the directive says assignment must be stable
    # in `id` order, so resolve the ordering dynamically rather than assume
    # creation order == id order.
    let(:lower)  { [ peer_x, peer_y ].min_by(&:id) }
    let(:higher) { [ peer_x, peer_y ].max_by(&:id) }

    # Stub the (private) derivation so both peers collide at salt 0 and
    # diverge at salt 1. Keyed by [peer_id, salt]; the nil-peer/zero-salt
    # fallback makes the pre-D11 code (which calls derive with no args)
    # fail cleanly rather than error — confirming RED.
    before do
      derived = {
        [ lower.id, 0 ]  => "10.0.0.1",
        [ lower.id, 1 ]  => "10.0.0.2",
        [ higher.id, 0 ] => "10.0.0.1",
        [ higher.id, 1 ] => "10.0.0.3"
      }
      allow_any_instance_of(described_class)
        .to receive(:derive_from_overlay) do |_instance, peer: nil, salt: 0|
          derived.fetch([ peer&.id, salt ]) { "10.9.#{salt}.0" }
        end
    end

    it "assigns DISTINCT ids to two peers that collide at salt 0" do
      expect(described_class.for_peer(lower)).not_to eq(described_class.for_peer(higher))
    end

    it "keeps the lower-id peer on salt 0 and perturbs the higher-id peer" do
      expect(described_class.for_peer(lower)).to eq("10.0.0.1")  # salt-0 kept
      expect(described_class.for_peer(higher)).to eq("10.0.0.3") # salt-1 perturb
    end

    it "is order-independent: resolving higher-then-lower matches lower-then-higher" do
      higher_first = described_class.for_peer(higher)
      lower_second = described_class.for_peer(lower)

      lower_first = described_class.for_peer(lower)
      higher_second = described_class.for_peer(higher)

      expect(lower_first).to eq(lower_second)
      expect(higher_first).to eq(higher_second)
    end

    it "raises CollisionDetected if no free salt exists within the bound" do
      # Every salt for every peer collides on the same id, so the
      # whole-account assignment (computed in one pass) can place the first
      # peer but saturates on the second — a loud failure, not a flap.
      allow_any_instance_of(described_class)
        .to receive(:derive_from_overlay).and_return("10.0.0.1")

      expect { described_class.for_peer(higher) }
        .to raise_error(described_class::CollisionDetected)
    end
  end

  describe "router_id_strategy explicit" do
    let(:account) { create(:account) }
    let(:network) { create(:sdwan_network, account: account) }
    let!(:peer) { create(:sdwan_peer, account: account, network: network) }

    context "with no override" do
      let!(:account_bgp) do
        create(:sdwan_account_bgp, account: account, router_id_strategy: "explicit")
      end

      it "warns and still returns a valid derived id" do
        allow(Rails.logger).to receive(:warn)
        result = described_class.for_peer(peer)

        expect(result).to match(/\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/)
        expect(Rails.logger)
          .to have_received(:warn).with(/router_id_strategy=explicit/).at_least(:once)
      end
    end

    context "with an override" do
      let!(:account_bgp) do
        create(:sdwan_account_bgp, account: account, router_id_strategy: "explicit")
      end

      it "returns the override and does NOT warn" do
        peer.update!(bgp_router_id_override: "198.51.100.4")

        allow(Rails.logger).to receive(:warn)
        expect(described_class.for_peer(peer)).to eq("198.51.100.4")
        expect(Rails.logger).not_to have_received(:warn).with(/router_id_strategy=explicit/)
      end
    end
  end
end
