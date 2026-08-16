# frozen_string_literal: true

require "rails_helper"

# Real-execution coverage for the autonomous VIP-failover executor fired by
# SdwanVipReachabilitySensor when a single-holder VIP's primary goes silent.
# Previously only stubbed (decision_engine_spec instance_doubles it), so the
# side-effectful failover (holder promotion + reroute) and its guard rails
# never actually ran. Exercises the real #perform end-to-end.
RSpec.describe System::Ai::Skills::SdwanVipFailoverExecutor do
  let(:account)   { create(:account) }
  let(:network)   { create(:sdwan_network, account: account) }
  let(:primary)   { create(:sdwan_peer, account: account, network: network) }
  let(:candidate) { create(:sdwan_peer, account: account, network: network) }
  let(:exec)      { described_class.new(account: account) }

  let(:vip) do
    create(:sdwan_virtual_ip, account: account, network: network, anycast: false,
           holder_peer_ids: [ primary.id ], failover_holder_peer_ids: [ candidate.id ])
  end

  describe "#execute" do
    it "fails when the VIP is not in the caller's account (cross-account isolation)" do
      other = create(:sdwan_virtual_ip) # its own, different account

      r = exec.execute(virtual_ip_id: other.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found in account/i)
    end

    it "treats an anycast VIP as informational (BGP handles re-convergence)" do
      # Anycast VIPs require >= 2 holders (all addresses are advertised at once).
      any = create(:sdwan_virtual_ip, account: account, network: network, anycast: true,
                   holder_peer_ids: [ primary.id, candidate.id ])

      r = exec.execute(virtual_ip_id: any.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :anycast)).to be true
      expect(r.dig(:data, :resolved)).to be false
    end

    it "fails when no failover candidates are configured" do
      vip.update!(failover_holder_peer_ids: [])

      r = exec.execute(virtual_ip_id: vip.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/failover candidates/i)
    end

    it "dry_run plans the promotion without changing holders" do
      r = exec.execute(virtual_ip_id: vip.id, dry_run: true)

      expect(r[:success]).to be true
      expect(r.dig(:data, :dry_run)).to be true
      expect(r.dig(:data, :would_promote_peer_id)).to eq(candidate.id)
      expect(vip.reload.holder_peer_ids).to eq([ primary.id ]) # untouched
    end

    it "promotes the next candidate to primary holder on a real failover" do
      r = exec.execute(virtual_ip_id: vip.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :resolved)).to be true
      expect(r.dig(:data, :previous_holder_peer_id)).to eq(primary.id)
      expect(r.dig(:data, :new_holder_peer_id)).to eq(candidate.id)
      expect(vip.reload.holder_peer_ids.first).to eq(candidate.id)
    end

    # IMP-d952c791e264 — this executor carried its own copy of the model's
    # precondition guards (its wording had already drifted), and like both
    # other copies it missed the standby whose peer row was deleted:
    # failover_holder_peer_ids is a bare uuid[] with no FK and
    # Sdwan::Executors::DeletePeer never scrubs it, so the sensor-driven
    # failover reached ::Sdwan::Peer.find inside the transaction.
    it "fails when the standby it would promote has been deleted" do
      dead = create(:sdwan_peer, account: account, network: network)
      vip.update!(failover_holder_peer_ids: [ dead.id ])
      dead.destroy!

      r = exec.execute(virtual_ip_id: vip.id)

      expect(r[:success]).to be false
      # Pinning the predicate's wording, not merely `success: false`: the
      # unfixed executor also answers false here, because BaseSkillExecutor's
      # blanket rescue turns the ActiveRecord::RecordNotFound raised deep in
      # the failover! transaction into a failure whose message happens to
      # contain the same id. `include(dead.id)` alone cannot tell a refused
      # failover from an attempted one that blew up.
      expect(r[:error]).to include(dead.id).and match(/not a live peer/)
      expect(vip.reload.holder_peer_ids).to eq([ primary.id ])
    end

    # A dry run exists to tell an operator what WOULD happen; over a tombstone
    # standby the honest answer is "nothing, because X" — not a
    # would_promote_peer_id naming a row that no longer exists.
    #
    # It stays a `success` PREVIEW rather than becoming a failure because
    # System::Fleet::DecisionEngine invokes the dry run solely to stamp
    # `skill_plan` on the approval request it then parks, and
    # skill_metadata_payload keys on skill_result[:data] — which
    # BaseSkillExecutor#failure does not carry. Answering with #failure would
    # trade a misleading card for an empty one.
    it "reports the blocker in a dry run instead of planning a doomed promotion" do
      dead = create(:sdwan_peer, account: account, network: network)
      vip.update!(failover_holder_peer_ids: [ dead.id ])
      dead.destroy!

      r = exec.execute(virtual_ip_id: vip.id, dry_run: true)

      expect(r[:success]).to be true
      expect(r.dig(:data, :blocked)).to be true
      expect(r.dig(:data, :note)).to include(dead.id).and match(/not a live peer/)
      expect(r.dig(:data, :would_promote_peer_id)).to be_nil,
                                                      "the preview still named a peer that cannot be promoted"
      expect(vip.reload.holder_peer_ids).to eq([ primary.id ])
    end

    # Positive control for the example above: an unblocked dry run must keep
    # naming its candidate, or "would_promote_peer_id is nil" is satisfied by a
    # preview that simply stopped planning anything.
    it "still names the candidate on an unblocked dry run" do
      r = exec.execute(virtual_ip_id: vip.id, dry_run: true)

      expect(r.dig(:data, :blocked)).to be false
      expect(r.dig(:data, :note)).to be_nil
      expect(r.dig(:data, :would_promote_peer_id)).to eq(candidate.id)
    end

    it "returns failure (not a raise) when failover! hits a StateError" do
      allow_any_instance_of(::Sdwan::VirtualIp)
        .to receive(:failover!).and_raise(::Sdwan::VirtualIp::StateError, "concurrent failover")

      r = exec.execute(virtual_ip_id: vip.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/concurrent failover/)
    end
  end
end
