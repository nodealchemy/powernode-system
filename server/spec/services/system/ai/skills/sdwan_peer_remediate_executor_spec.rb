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

    it "rotates the keypair, revokes the old key, chains the audit trail, and resets the peer to pending" do
      old_key = peer.reload.active_key

      r = exec.execute(peer_id: peer.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :resolved)).to be true
      expect(r.dig(:data, :rotated_from_key_id)).to eq(old_key.id)

      new_key = peer.reload.active_key
      expect(new_key.id).to eq(r.dig(:data, :new_key_id))
      expect(new_key.id).not_to eq(old_key.id)
      expect(new_key.rotated_from_id).to eq(old_key.id) # rotation chain preserved
      expect(old_key.reload.revoked?).to be true
      expect(peer.status).to eq("pending")
      expect(peer.last_compiled_at).to be_nil
    end
  end
end
