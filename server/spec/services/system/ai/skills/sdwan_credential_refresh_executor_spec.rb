# frozen_string_literal: true

require "rails_helper"

# Real-execution coverage for the autonomous membership-credential refresh
# (IMP-df40782d3f4d). The invariant this executor exists for: refreshing an
# expiring MC must never touch the peer's WireGuard key material — key
# rotation cuts the working tunnel of exactly the peer that isn't polling
# for a replacement, which is the peer whose MC ages out in the first place.
RSpec.describe System::Ai::Skills::SdwanCredentialRefreshExecutor do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  # :active — a still-connected peer with a working tunnel is exactly the
  # scenario: its agent has stopped pulling, so its MC ages out while the
  # data plane is fine.
  let(:peer) do
    p = create(:sdwan_peer, :active, account: account, network: network,
                                     last_compiled_at: 1.hour.ago)
    Sdwan::KeyDistributor.ensure_key_for!(p)
    p.reload
  end
  let(:exec) { described_class.new(account: account) }

  # An MC aged past its refresh boundary but short of hard expiry — the
  # state the SdwanCredentialExpirySensor fingerprints. Aged coherently
  # (as if issued 50 minutes into its 1h TTL) so the row still validates
  # when the signer supersedes it.
  def issue_expiring_mc!
    mc = Sdwan::MembershipCredentialSigner.issue!(peer: peer)
    mc.update_columns(issued_at: 50.minutes.ago, not_before: 50.minutes.ago,
                      refresh_after: 20.minutes.ago, not_after: 10.minutes.from_now)
    mc
  end

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

    it "dry_run reports the plan without issuing a credential" do
      mc = issue_expiring_mc!

      r = exec.execute(peer_id: peer.id, dry_run: true)

      expect(r[:success]).to be true
      expect(r.dig(:data, :dry_run)).to be true
      expect(r.dig(:data, :current_credential_id)).to eq(mc.id)
      expect(r.dig(:data, :would_issue)).to be true
      expect(Sdwan::MembershipCredential.where(sdwan_peer_id: peer.id).count).to eq(1)
    end

    it "re-issues the credential and supersedes the expiring row, leaving the WG key untouched" do
      mc = issue_expiring_mc!
      wg_key = peer.active_key

      r = exec.execute(peer_id: peer.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :resolved)).to be true
      expect(r.dig(:data, :superseded_credential_id)).to eq(mc.id)

      fresh = Sdwan::MembershipCredential.find(r.dig(:data, :membership_credential_id))
      expect(fresh.id).not_to eq(mc.id)
      expect(fresh.status).to eq("active")
      expect(fresh.revision).to eq(mc.revision + 1)
      expect(fresh.not_after).to be > 30.minutes.from_now
      expect(mc.reload.status).to eq("revoked") # superseded; envelope stays wire-valid until not_after

      # The load-bearing invariant: no key material was touched and no
      # re-handshake was forced (contrast SdwanPeerRemediateExecutor, which
      # resets status to pending and clears last_compiled_at).
      expect(wg_key.reload.revoked?).to be false
      expect(peer.reload.active_key.id).to eq(wg_key.id)
      expect(peer.status).to eq("active")
      expect(peer.last_compiled_at).to be_present
    end

    it "is idempotent — a fresh credential is returned, not re-issued" do
      fresh = Sdwan::MembershipCredentialSigner.issue!(peer: peer)

      r = exec.execute(peer_id: peer.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :membership_credential_id)).to eq(fresh.id)
      expect(r.dig(:data, :superseded_credential_id)).to be_nil
      expect(Sdwan::MembershipCredential.where(sdwan_peer_id: peer.id).count).to eq(1)
    end

    it "surfaces a signer failure instead of raising (so the F3-11 streak can escalate)" do
      issue_expiring_mc!
      peer.active_key.update_columns(revoked_at: Time.current)
      peer.reload # active_key reads the loaded keys collection

      r = exec.execute(peer_id: peer.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/credential refresh failed/i)
    end
  end
end
