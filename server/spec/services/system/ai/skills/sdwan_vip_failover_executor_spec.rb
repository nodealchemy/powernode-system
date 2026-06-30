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

    it "returns failure (not a raise) when failover! hits a StateError" do
      allow_any_instance_of(::Sdwan::VirtualIp)
        .to receive(:failover!).and_raise(::Sdwan::VirtualIp::StateError, "concurrent failover")

      r = exec.execute(virtual_ip_id: vip.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/concurrent failover/)
    end
  end
end
