# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::PeerDetacher do
  let(:account)  { create(:account) }
  let(:network)  { create(:sdwan_network, account: account) }
  let(:instance) { create(:system_node_instance, account: account) }

  def enroll
    Sdwan::PeerEnroller.call(network: network, node_instance: instance)
  end

  describe ".call" do
    context "when the node_instance has an active SDWAN peer" do
      before { enroll }

      it "destroys the Sdwan::Peer row" do
        expect { described_class.call(node_instance: instance) }
          .to change(Sdwan::Peer, :count).by(-1)
      end

      it "returns the destroyed peer id" do
        peer = Sdwan::Peer.find_by(node_instance_id: instance.id)

        result = described_class.call(node_instance: instance)

        expect(result).to eq([ peer.id ])
      end

      it "cascades to the peer's keys" do
        peer = Sdwan::Peer.find_by(node_instance_id: instance.id)
        key_id = peer.active_key.id

        described_class.call(node_instance: instance)

        expect(Sdwan::PeerKey.where(id: key_id)).not_to exist
      end

      it "cascades to the peer's membership credentials (IMP 019fe76e-5009)" do
        # dryrun-20260809d teardown: every auto-detach failed
        # PG::ForeignKeyViolation because membership credentials still
        # referenced the peer — Peer cascaded keys + subnet_advertisements
        # but never declared this association, so terminated instances left
        # orphaned peers polluting the fabric.
        peer = Sdwan::Peer.find_by(node_instance_id: instance.id)
        credential = Sdwan::MembershipCredential.create!(
          account: account, peer: peer, network: network,
          status: "active", revision: 1,
          issued_at: 1.hour.ago, not_before: 1.hour.ago,
          not_after: 1.day.from_now, refresh_after: 12.hours.from_now,
          envelope_json: '{"rev":1}', signature_b64: "AAAA",
          constellation_handle: "acct-spec"
        )

        expect { described_class.call(node_instance: instance) }
          .to change(Sdwan::Peer, :count).by(-1)
        expect(Sdwan::MembershipCredential.where(id: credential.id)).not_to exist
      end
    end

    context "when scoped to a specific network" do
      let(:other_network) { create(:sdwan_network, account: account) }

      before do
        enroll
        Sdwan::PeerEnroller.call(network: other_network, node_instance: instance)
      end

      it "only detaches the peer for the given network" do
        expect { described_class.call(node_instance: instance, network: network) }
          .to change(Sdwan::Peer, :count).by(-1)

        expect(Sdwan::Peer.where(node_instance_id: instance.id, sdwan_network_id: other_network.id)).to exist
        expect(Sdwan::Peer.where(node_instance_id: instance.id, sdwan_network_id: network.id)).not_to exist
      end
    end

    context "when the node_instance has no SDWAN peer" do
      it "is a no-op that returns an empty array" do
        expect(described_class.call(node_instance: instance)).to eq([])
      end
    end

    context "central NodeInstancePeer capability mirroring" do
      let!(:central) { create(:system_node_instance_peer, node_instance: instance, account: account) }

      it "removes the network entry from the central capabilities when it's the only membership" do
        enroll

        described_class.call(node_instance: instance)

        expect(central.reload.capabilities["sdwan"]).to be_nil
      end

      it "preserves other networks' entries when scoped to a single network" do
        other_network = create(:sdwan_network, account: account)
        enroll
        Sdwan::PeerEnroller.call(network: other_network, node_instance: instance)

        described_class.call(node_instance: instance, network: network)

        networks = central.reload.capabilities.dig("sdwan", "networks")
        expect(networks.map { |n| n["network_id"] }).to contain_exactly(other_network.id)
      end
    end
  end
end
