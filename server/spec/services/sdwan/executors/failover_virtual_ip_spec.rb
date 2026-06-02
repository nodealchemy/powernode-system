# frozen_string_literal: true

require "rails_helper"

# Regression + contract spec for the FailoverVirtualIp executor. The executor
# previously called `vip.failover!(target_peer_id:)`, but the model signature is
# `failover!(reason:, triggered_by_user:, correlation_id:)` — an unknown keyword
# that raises ArgumentError on every invocation. `instance_double` verifies the
# real signature, so the old call fails this spec exactly as production would.
RSpec.describe Sdwan::Executors::FailoverVirtualIp do
  let(:vip) do
    instance_double(
      "Sdwan::VirtualIp",
      id: "vip-1",
      holder_peer_ids: %w[p2 p1],
      failover_holder_peer_ids: %w[p1 p3],
      state: "active",
      reload: nil
    )
  end

  before do
    allow(::Sdwan::VirtualIp).to receive(:find).with("vip-1").and_return(vip)
    allow(vip).to receive(:failover!)
    allow(vip).to receive(:update!)
  end

  describe ".execute" do
    it "delegates to VirtualIp#failover! using the model's real keyword contract" do
      described_class.execute({ vip_id: "vip-1" }, deferred_operation: nil)

      expect(vip).to have_received(:failover!).with(
        reason: "manual_failover",
        triggered_by_user: nil,
        correlation_id: nil
      )
    end

    it "returns the post-failover holder state" do
      result = described_class.execute({ vip_id: "vip-1" }, deferred_operation: nil)

      expect(result[:success]).to be true
      expect(result[:data]).to include(
        vip_id: "vip-1",
        holders: %w[p2 p1],
        failover_holders: %w[p1 p3],
        state: "active"
      )
    end

    it "moves a named target_peer_id to the head of the failover queue before failing over" do
      described_class.execute({ vip_id: "vip-1", target_peer_id: "p3" }, deferred_operation: nil)

      expect(vip).to have_received(:update!).with(failover_holder_peer_ids: %w[p3 p1])
      expect(vip).to have_received(:failover!)
    end

    it "ignores a target_peer_id that is not a configured failover candidate" do
      described_class.execute({ vip_id: "vip-1", target_peer_id: "p9" }, deferred_operation: nil)

      expect(vip).not_to have_received(:update!)
      expect(vip).to have_received(:failover!)
    end
  end
end
