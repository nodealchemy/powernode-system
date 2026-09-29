# frozen_string_literal: true

require "rails_helper"

# IMP-2e7816b5ee95 — the failure and interleaving edges of the one author of an
# in-place peer key rotation. The happy path, the gate and the no-secret scans
# live in spec/services/ai/tools/sdwan_tool_rotate_peer_key_spec.rb.
RSpec.describe Sdwan::PeerKeyRotationService do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let!(:peer) do
    p = create(:sdwan_peer, :active, account: account, network: network)
    Sdwan::KeyDistributor.ensure_key_for!(p)
    p.reload
  end
  let!(:original_key) { peer.active_key }

  subject(:service) { described_class.new }

  # Critic L2. KeyDistributor writes the new private half to Vault INSIDE the
  # transaction, and Vault is not transactional: when a later step (the audit
  # row) raises, the PeerKey rows roll back and the secret would stay behind at
  # a path no row points at.
  describe "a failure after the Vault write" do
    let(:stored_ids) { [] }

    before do
      allow(Sdwan::KeyDistributor).to receive(:rotate!).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap { |key| stored_ids << key.id }
      end
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "audit sink unavailable")
    end

    it "rolls the rotation back and purges the orphaned credential, then re-raises" do
      expect_any_instance_of(Security::VaultCredentialProvider).to receive(:purge_credential!) do |_provider, **kwargs|
        expect(kwargs).to eq(credential_type: Sdwan::PeerKey.vault_credential_type, credential_id: stored_ids.sole)
        true
      end

      expect { service.rotate!(peer: peer, reason: "suspected key leak") }
        .to raise_error(ActiveRecord::StatementInvalid, /audit sink unavailable/)

      expect(original_key.reload.revoked?).to be(false)
      expect(Sdwan::PeerKey.where(sdwan_peer_id: peer.id).pluck(:id)).to eq([ original_key.id ])
    end

    it "surfaces the ORIGINAL failure when the purge itself fails" do
      allow_any_instance_of(Security::VaultCredentialProvider).to receive(:purge_credential!)
        .and_raise(StandardError, "vault unreachable")

      expect { service.rotate!(peer: peer, reason: "suspected key leak") }
        .to raise_error(ActiveRecord::StatementInvalid, /audit sink unavailable/)
    end
  end

  # Critic L4. The membership credential names the WireGuard public key. A
  # second rotation of the same peer can commit after this rotation's credential
  # re-issue has read ITS key — the re-issues then land in either order, and the
  # served envelope would name a superseded key until the refresh window.
  describe "a second rotation interleaved with the credential re-issue" do
    it "re-issues once more so the active credential names the key active at the end" do
      interleaved = nil
      calls = 0
      allow(Sdwan::MembershipCredentialSigner).to receive(:issue!).and_wrap_original do |original, **kwargs|
        calls += 1
        original.call(**kwargs).tap do
          interleaved ||= Sdwan::KeyDistributor.rotate!(peer: Sdwan::Peer.find(peer.id), reason: "concurrent")
        end
      end

      result = service.rotate!(peer: peer, reason: "suspected key leak")

      active = Sdwan::Peer.find(peer.id).active_key
      expect(active.id).to eq(interleaved.id)
      expect(result.new_key.id).not_to eq(active.id)
      expect(calls).to eq(2)
      expect(result.membership_credential_reissued).to be(true)

      mc = Sdwan::MembershipCredential.where(sdwan_peer_id: peer.id, status: "active").sole
      expect(JSON.parse(mc.envelope_json)["wg_pubkey"]).to eq(active.public_key)
    end

    it "issues exactly once when nothing interleaves" do
      allow(Sdwan::MembershipCredentialSigner).to receive(:issue!).and_call_original

      service.rotate!(peer: peer, reason: "suspected key leak")

      expect(Sdwan::MembershipCredentialSigner).to have_received(:issue!).once
    end
  end
end
