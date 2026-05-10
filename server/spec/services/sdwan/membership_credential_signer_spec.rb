# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::MembershipCredentialSigner, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::MembershipCredential.where(account_id: account.id).delete_all
    Sdwan::ConstellationSigningKey.where(account_id: account.id).delete_all
    Sdwan::PeerKey.joins(:peer).where(sdwan_peers: { account_id: account.id }).delete_all
    Sdwan::Peer.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "mc-net-#{SecureRandom.hex(3)}") }
  let!(:node)    { sdwan_test_node(account: account) }
  let!(:inst)    { sdwan_test_node_instance(node: node) }
  let!(:peer) do
    p = Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst,
                            publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
    Sdwan::KeyDistributor.ensure_key_for!(p)
    p.reload
  end

  describe ".issue!" do
    it "creates an active MC with revision 1 on first issue" do
      mc = described_class.issue!(peer: peer)
      expect(mc).to be_persisted
      expect(mc).to be_active
      expect(mc.revision).to eq(1)
      expect(mc.constellation_handle).to start_with("acct-")
    end

    it "renders an envelope embedding peer + network identifiers" do
      mc = described_class.issue!(peer: peer)
      env = JSON.parse(mc.envelope_json)
      expect(env["aud"]).to eq("net-#{network.id.to_s.delete('-').first(8)}")
      expect(env["wg_pubkey"]).to eq(peer.active_key.public_key)
      expect(env["addr_v6"]).to eq(peer.assigned_address.split("/").first)
      expect(env["rev"]).to eq(1)
      expect(env["endpoints"]).to be_an(Array)
      expect(env["endpoints"].first["host"]).to eq("2001:db8::1")
    end

    it "produces a base64 signature that verifies against the constellation public key" do
      mc = described_class.issue!(peer: peer)
      holder = Sdwan::ConstellationSigningKey.find_by!(
        account_id: account.id,
        handle: mc.constellation_handle
      )
      pub_raw = Base64.decode64(holder.public_key_b64)
      pkey = OpenSSL::PKey.new_raw_public_key("ED25519", pub_raw)
      sig_raw = Base64.decode64(mc.signature_b64)
      expect(pkey.verify(nil, sig_raw, mc.envelope_json)).to be true
    end

    it "signs the canonical envelope (sorted keys at every level)" do
      mc = described_class.issue!(peer: peer)
      parsed = JSON.parse(mc.envelope_json)
      reserialized = JSON.generate(parsed.sort.to_h)
      # The signed bytes must be the exact JSON we persisted, not a
      # re-rendered shape.
      expect(mc.envelope_json).to eq(reserialized)
    end

    it "rejects ttl_seconds <= refresh_seconds" do
      expect {
        described_class.issue!(peer: peer, ttl_seconds: 100, refresh_seconds: 200)
      }.to raise_error(Sdwan::MembershipCredentialSigner::SigningError, /refresh_seconds/)
    end

    it "raises if peer has no active WG key" do
      peer.active_key.update!(revoked_at: Time.current, revocation_reason: "test")
      peer.reload
      expect {
        described_class.issue!(peer: peer)
      }.to raise_error(Sdwan::MembershipCredentialSigner::SigningError, /WireGuard key/)
    end

    it "supersedes the previous active MC and bumps revision" do
      first = described_class.issue!(peer: peer)
      second = described_class.issue!(peer: peer)

      expect(second.revision).to eq(2)
      expect(second).to be_active
      first.reload
      expect(first).to be_revoked
      expect(first.revocation_reason).to start_with("rotated_revision_")

      live = Sdwan::MembershipCredential.where(sdwan_peer_id: peer.id, sdwan_network_id: network.id, status: "active")
      expect(live.count).to eq(1)
      expect(live.first.id).to eq(second.id)
    end

    it "re-uses constellation signing key across issues (no double-mint)" do
      first = described_class.issue!(peer: peer)
      second = described_class.issue!(peer: peer)
      expect(first.signed_with_vault_path).to eq(second.signed_with_vault_path)
    end

    it "emits a sdwan.credential_issued FleetEvent on success" do
      expect(::System::Fleet::EventBroadcaster).to receive(:emit!)
        .with(hash_including(kind: "sdwan.credential_issued", severity: :low))
        .and_call_original
      described_class.issue!(peer: peer)
    end
  end

  describe ".ensure_fresh!" do
    it "returns the existing MC if it is not yet due for refresh" do
      first = described_class.issue!(peer: peer)
      second = described_class.ensure_fresh!(peer: peer)
      expect(second.id).to eq(first.id)
      expect(second.revision).to eq(1)
    end

    it "issues a new MC when the current one has crossed refresh_after" do
      first = described_class.issue!(peer: peer)
      # Push not_before back so the refresh_after we set passes the
      # `refresh_after >= not_before` validator.
      first.update!(not_before: 2.hours.ago, refresh_after: 1.minute.ago)
      second = described_class.ensure_fresh!(peer: peer)
      expect(second.revision).to eq(2)
      expect(second.id).not_to eq(first.id)
    end

    it "issues when no MC exists yet" do
      mc = described_class.ensure_fresh!(peer: peer)
      expect(mc.revision).to eq(1)
    end
  end

  describe ".revoke_for!" do
    it "revokes the active MC and emits a sdwan.credential_revoked event" do
      first = described_class.issue!(peer: peer)
      expect(::System::Fleet::EventBroadcaster).to receive(:emit!)
        .with(hash_including(kind: "sdwan.credential_revoked", severity: :medium))
      result = described_class.revoke_for!(peer: peer, reason: "test_revocation")
      expect(result.id).to eq(first.id)
      first.reload
      expect(first).to be_revoked
      expect(first.revocation_reason).to eq("test_revocation")
    end

    it "returns nil when no live MC exists" do
      expect(described_class.revoke_for!(peer: peer)).to be_nil
    end
  end

  describe "failure path" do
    it "emits sdwan.credential_refresh_failed and re-raises on signer error" do
      allow_any_instance_of(described_class).to receive(:render_envelope).and_raise(StandardError, "boom")
      expect(::System::Fleet::EventBroadcaster).to receive(:emit!)
        .with(hash_including(kind: "sdwan.credential_refresh_failed", severity: :high))
      expect { described_class.issue!(peer: peer) }.to raise_error(StandardError, "boom")
    end
  end
end
