# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::Executors::ProposeFederationPeer do
  let(:account) { create(:account) }
  let(:deferred_operation) { instance_double("Ai::DeferredOperation", account: account, requested_by: nil, ai_agent: nil) }

  let(:attributes) do
    {
      remote_instance_url: "https://child.example.com",
      remote_instance_id: SecureRandom.uuid,
      peer_kind: "platform",
      spawn_role: "parent",
      spawn_mode: "managed_child"
    }
  end

  describe ".execute" do
    it "creates a proposed federation peer and mints a single-use acceptance token" do
      result = described_class.execute({ attributes: attributes }, deferred_operation: deferred_operation)

      expect(result[:success]).to be true
      peer_id = result[:data][:federation_peer_id]
      expect(peer_id).to be_present

      peer = ::System::FederationPeer.find(peer_id)
      expect(peer.account_id).to eq(account.id)
      expect(peer.status).to eq("proposed")

      # Token plaintext returned ONCE; only the digest persisted.
      expect(result[:data][:acceptance_token_plaintext]).to be_present
      expect(result[:data][:acceptance_token_expires_at]).to be_present
      expect(result[:data][:note]).to match(/EXACTLY ONCE/)

      expect(peer.acceptance_token_digest).to be_present
      expect(peer.acceptance_token_digest)
        .to eq(::Digest::SHA256.hexdigest(result[:data][:acceptance_token_plaintext]))
    end

    it "honors a custom token_ttl_seconds" do
      result = described_class.execute(
        { attributes: attributes.merge(token_ttl_seconds: 3600) },
        deferred_operation: deferred_operation
      )
      peer = ::System::FederationPeer.find(result[:data][:federation_peer_id])
      expect(peer.acceptance_token_expires_at).to be_within(60.seconds).of(1.hour.from_now)
    end

    it "skips token generation when generate_token is false" do
      result = described_class.execute(
        { attributes: attributes.merge(generate_token: false) },
        deferred_operation: deferred_operation
      )
      expect(result[:success]).to be true
      expect(result[:data]).not_to have_key(:acceptance_token_plaintext)

      peer = ::System::FederationPeer.find(result[:data][:federation_peer_id])
      expect(peer.acceptance_token_digest).to be_nil
    end

    it "does not persist generate_token / token_ttl_seconds as peer attributes" do
      # These are control flags, not columns — they must be stripped before
      # FederationPeer.create! or it would raise unknown attribute.
      expect {
        described_class.execute(
          { attributes: attributes.merge(generate_token: true, token_ttl_seconds: 7200) },
          deferred_operation: deferred_operation
        )
      }.not_to raise_error
    end
  end

  describe ".preview" do
    it "summarizes the remote instance url" do
      preview = described_class.preview({ attributes: attributes })
      expect(preview[:summary]).to include("child.example.com")
      expect(preview[:impact]).to include("acceptance token")
    end
  end
end
