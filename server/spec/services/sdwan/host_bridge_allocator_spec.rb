# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::HostBridgeAllocator, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:node)    { sdwan_test_node(account: account) }
  let(:host_a)  { sdwan_test_node_instance(node: node) }
  let(:host_b)  { sdwan_test_node_instance(node: node) }

  before do
    Sdwan::HostBridge.where(account_id: account.id).delete_all
  end

  describe ".allocate!" do
    it "creates a new HostBridge with the lowest available short_id (1)" do
      hb = described_class.allocate!(host: host_a)
      expect(hb).to be_persisted
      expect(hb.short_id).to eq(1)
      expect(hb.bridge_name).to eq("pwnbr-1")
      expect(hb.kind).to eq("linux")
      expect(hb.account_id).to eq(account.id)
    end

    it "is idempotent — calling twice returns the same row, not a new one" do
      first  = described_class.allocate!(host: host_a)
      second = described_class.allocate!(host: host_a)
      expect(second.id).to eq(first.id)
      expect(Sdwan::HostBridge.where(node_instance_id: host_a.id).count).to eq(1)
    end

    it "permits the same short_id on a different host" do
      a = described_class.allocate!(host: host_a)
      b = described_class.allocate!(host: host_b)
      expect(a.short_id).to eq(1)
      expect(b.short_id).to eq(1)
      expect(a.id).not_to eq(b.id)
    end

    it "raises InvalidArguments when host is nil" do
      expect { described_class.allocate!(host: nil) }
        .to raise_error(Sdwan::HostBridgeAllocator::InvalidArguments)
    end

    it "rejects unknown kind values" do
      expect { described_class.allocate!(host: host_a, kind: "vxlan") }
        .to raise_error(Sdwan::HostBridgeAllocator::InvalidArguments)
    end

    it "supports kind: 'ovs' (Phase O2 forward-compat)" do
      hb = described_class.allocate!(host: host_a, kind: "ovs")
      expect(hb).to be_persisted
      expect(hb.kind).to eq("ovs")
    end

    it "treats different kinds independently — same host can hold one of each" do
      linux = described_class.allocate!(host: host_a, kind: "linux")
      ovs   = described_class.allocate!(host: host_a, kind: "ovs")
      expect(linux.id).not_to eq(ovs.id)
      expect(linux.kind).to eq("linux")
      expect(ovs.kind).to eq("ovs")
      # Both rows occupy separate short_ids on the same host.
      expect([linux.short_id, ovs.short_id].uniq.length).to eq(2)
    end

    it "readopts a removed row instead of allocating a new one" do
      hb = described_class.allocate!(host: host_a)
      described_class.release!(hb, force: true)
      hb.reload
      expect(hb.state).to eq("removed")

      readopted = described_class.allocate!(host: host_a)
      expect(readopted.id).to eq(hb.id)
      expect(readopted.state).to eq("active")
    end

    it "returns the existing draining row idempotently (does not allocate a second one)" do
      hb = described_class.allocate!(host: host_a)
      described_class.release!(hb)  # draining (default)
      hb.reload
      expect(hb.state).to eq("draining")

      second = described_class.allocate!(host: host_a)
      expect(second.id).to eq(hb.id)
      # Stays in draining — caller's responsibility to mark active
      # explicitly via the agent applier reconcile.
      expect(second.state).to eq("draining")
    end

    it "scopes the bridge to the host's account" do
      hb = described_class.allocate!(host: host_a)
      expect(hb.account_id).to eq(host_a.account.id)
    end

    it "fills gaps left by hard-deleted rows (lowest-unused wins)" do
      # Manually create two bridges of different kinds to occupy
      # short_ids 1 and 2; remove the first; allocate a new bridge
      # and verify it picks short_id 1.
      Sdwan::HostBridge.create!(account: account, node_instance: host_a,
                                short_id: 1, bridge_name: "pwnbr-1",
                                kind: "linux", state: "removed")
      Sdwan::HostBridge.create!(account: account, node_instance: host_a,
                                short_id: 2, bridge_name: "pwnbr-2",
                                kind: "ovs")

      # Hard-delete the row at short_id 1 to free the slot. Removed
      # rows still hold their id until a reaper hard-deletes them;
      # we simulate that here.
      Sdwan::HostBridge.where(node_instance_id: host_a.id,
                              short_id: 1).delete_all

      # Allocating a new linux bridge should fill the gap at short_id 1.
      new_hb = described_class.allocate!(host: host_a, kind: "linux")
      expect(new_hb.short_id).to eq(1)
    end

    # ------------------------------------------------------------------
    # Phase O2 — profile-aware kind defaulting
    # ------------------------------------------------------------------
    describe "profile-aware kind defaulting" do
      it "defaults kind to 'linux' for a lightweight-profile host" do
        host_a.update!(network_profile: "lightweight")

        hb = described_class.allocate!(host: host_a)
        expect(hb.kind).to eq("linux")
      end

      it "defaults kind to 'ovs' for a heavyweight-profile host" do
        host_a.update!(network_profile: "heavyweight")

        hb = described_class.allocate!(host: host_a)
        expect(hb.kind).to eq("ovs")
      end

      it "honours an explicit kind: even when it disagrees with the host profile" do
        # Operator overrides during a staged rollout / recovery — a
        # heavyweight host can be temporarily forced onto a Linux
        # bridge, and the allocator must respect that.
        host_a.update!(network_profile: "heavyweight")

        hb = described_class.allocate!(host: host_a, kind: "linux")
        expect(hb.kind).to eq("linux")
      end

      it "honours kind: 'ovs' on a lightweight host (operator override path)" do
        host_a.update!(network_profile: "lightweight")

        hb = described_class.allocate!(host: host_a, kind: "ovs")
        expect(hb.kind).to eq("ovs")
      end

      it "falls back to 'linux' when the host has no recognisable profile" do
        # network_profile defaults to lightweight at insert time, but
        # we belt-and-suspenders the resolver anyway. Stub instead of
        # writing an unsupported value (the column has a CHECK).
        allow(host_a).to receive(:network_profile).and_return(nil)

        hb = described_class.allocate!(host: host_a)
        expect(hb.kind).to eq("linux")
      end
    end
  end

  describe ".release!" do
    let!(:bridge) { described_class.allocate!(host: host_a) }

    it "transitions to draining by default" do
      described_class.release!(bridge)
      expect(bridge.reload.state).to eq("draining")
      expect(bridge.draining_at).to be_present
    end

    it "transitions to removed when force: true" do
      described_class.release!(bridge, force: true)
      expect(bridge.reload.state).to eq("removed")
      expect(bridge.removed_at).to be_present
    end
  end
end
