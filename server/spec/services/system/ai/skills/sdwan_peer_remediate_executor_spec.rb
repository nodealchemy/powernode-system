# frozen_string_literal: true

require "rails_helper"

# Real-execution coverage for the autonomous "reset the tunnel" peer remediation
# (rotate the peer keypair, then force the agent to re-establish the tunnel on
# the next reconcile). Previously only stubbed (decision_engine_spec
# instance_doubles it), so the real Sdwan::KeyDistributor.rotate! — otherwise
# uncovered — never ran. Exercises the real #perform end-to-end.
RSpec.describe System::Ai::Skills::SdwanPeerRemediateExecutor do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:peer)    { create(:sdwan_peer, account: account, network: network) }
  let(:exec)    { described_class.new(account: account) }

  before { Sdwan::KeyDistributor.ensure_key_for!(peer) }

  describe "#execute" do
    it "fails for an unknown peer id" do
      r = exec.execute(peer_id: SecureRandom.uuid)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found in account/i)
    end

    it "fails for a peer owned by another account (cross-account isolation)" do
      foreign = create(:sdwan_peer) # its own, different account

      r = exec.execute(peer_id: foreign.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found in account/i)
    end

    it "dry_run reports the plan without rotating the key" do
      old_key = peer.reload.active_key

      r = exec.execute(peer_id: peer.id, dry_run: true)

      expect(r[:success]).to be true
      expect(r.dig(:data, :dry_run)).to be true
      expect(r.dig(:data, :would_rotate_from)).to eq(old_key.id)
      expect(peer.reload.active_key.id).to eq(old_key.id) # not rotated
      expect(old_key.reload.revoked?).to be false
    end

    # IMP-01a0ed52 — the executor is diagnosis only. Safety in code: it never
    # reaches Sdwan::KeyDistributor, whatever a policy row says.
    [ "notify_and_proceed", "auto_approve" ].each do |verb|
      it "refuses to rotate and writes nothing when system.sdwan_peer_remediate is #{verb}" do
        Ai::InterventionPolicy.create!(account: account, scope: "global", action_category: "system.sdwan_peer_remediate",
                                       policy: verb, is_active: true)
        old_key = peer.reload.active_key
        expect(Sdwan::KeyDistributor).not_to receive(:rotate!)

        r = exec.execute(gated: true, peer_id: peer.id)

        expect(r[:success]).to be false
        expect(r[:error]).to match(/system_sdwan_rotate_peer_key|approval/i)
        expect(peer.reload.active_key.id).to eq(old_key.id)
        expect(old_key.reload.revoked?).to be false
        expect(r.to_json).not_to match(/private/i)
      end
    end
  end
end
