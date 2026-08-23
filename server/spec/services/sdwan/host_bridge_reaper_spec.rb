# frozen_string_literal: true

require "rails_helper"

# IMP-53a5c597ec8c — before this reaper, `draining` was a one-way door.
#
# The oracle here is NOT "the row's state string changed". It is that the
# drain window actually CLOSES in the terms that made draining meaningful:
# a drained bridge is still `compilable` (so the topology compiler keeps
# emitting it and Sdwan::HostBridgeResolver still answers for the host)
# until the window elapses, and afterwards it is neither. That pair is the
# whole difference between a grace period and a leak.
RSpec.describe Sdwan::HostBridgeReaper do
  let(:account) { create(:account) }

  # Fetch helpers are `def`, not `let`: each probes CURRENT state, and a
  # memoized probe answering before the sweep would assert nothing.
  def host
    @host ||= create(:system_node_instance, account: account)
  end

  def drained_bridge(draining_at:)
    bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: host, kind: "linux")
    bridge.mark_active!
    ::Sdwan::HostBridgeAllocator.release!(bridge)
    bridge.update_column(:draining_at, draining_at)
    bridge
  end

  def state_of(bridge)
    ::Sdwan::HostBridge.find(bridge.id).state
  end

  def serving?(bridge)
    ::Sdwan::HostBridge.where(id: bridge.id).compilable.exists?
  end

  describe "#run!" do
    it "leaves a bridge still inside its grace window serving" do
      bridge = drained_bridge(draining_at: 1.hour.ago)

      described_class.run!

      expect(state_of(bridge)).to eq("draining")
      expect(serving?(bridge)).to be(true),
                                 "the reaper cut a bridge whose in-flight taps had not been given the window"
      expect(::Sdwan::HostBridgeResolver.bridge_present?(host)).to be(true)
    end

    it "removes a bridge past the window and stops it being emitted" do
      bridge = drained_bridge(draining_at: (described_class::GRACE_WINDOW + 1.hour).ago)

      result = described_class.run!

      expect(result.ok?).to be(true)
      expect(result.reaped_bridges).to eq(1)
      expect(state_of(bridge)).to eq("removed")
      expect(serving?(bridge)).to be(false),
                                  "the row says removed but the compiler would still emit it"
      expect(::Sdwan::HostBridgeResolver.bridge_present?(host)).to be(false)
    end

    # The property the whole change rests on: a plain release is no longer
    # terminal-by-omission. Without the reaper this bridge stays compilable
    # forever, which is why drain could not be defaulted to on the operator
    # surface.
    it "makes a non-forced release eventually complete" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: host, kind: "linux")
      bridge.mark_active!
      ::Sdwan::HostBridgeAllocator.release!(bridge)

      expect(serving?(bridge)).to be(true), "drain should keep serving during the window"

      bridge.update_column(:draining_at, (described_class::GRACE_WINDOW + 1.minute).ago)
      described_class.run!

      expect(serving?(bridge)).to be(false), "the drain window never closed — release is a leak"
    end

    it "does not touch active, pending or already-removed rows" do
      pending_bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: host, kind: "linux")
      other = create(:system_node_instance, account: account)
      active_bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: other, kind: "linux")
      active_bridge.mark_active!

      expect(described_class.run!.reaped_bridges).to eq(0)
      expect(state_of(pending_bridge)).to eq("pending")
      expect(state_of(active_bridge)).to eq("active")
    end

    # Conservative direction: a row whose age cannot be established keeps
    # serving rather than being swept on an assumed age.
    it "skips a draining row with no draining_at rather than assuming it is old" do
      bridge = drained_bridge(draining_at: nil)

      expect(described_class.run!.reaped_bridges).to eq(0)
      expect(state_of(bridge)).to eq("draining")
    end
  end
end
