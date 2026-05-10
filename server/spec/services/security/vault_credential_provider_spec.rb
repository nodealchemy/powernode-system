# frozen_string_literal: true

require "rails_helper"

# Phase N0 of the in-house encrypted mesh overlay roadmap added two new
# VaultCredential types: `node_signing_key` and `constellation_signing_key`.
# This spec asserts the registry surface so future additions don't silently
# drop them, and exercises the round-trip through the DB-fallback path
# (Vault unavailable in test env per the provider's own #vault_available?).
RSpec.describe Security::VaultCredentialProvider, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:provider) { described_class.new(account_id: account.id) }

  describe "CREDENTIAL_TYPES registry" do
    it "exposes node_signing_key" do
      expect(described_class::CREDENTIAL_TYPES).to include(node_signing_key: "sdwan-node-signing-keys")
    end

    it "exposes constellation_signing_key" do
      expect(described_class::CREDENTIAL_TYPES).to include(constellation_signing_key: "sdwan-constellation-signing-keys")
    end

    it "still exposes the pre-existing wireguard_node_key (no regression)" do
      expect(described_class::CREDENTIAL_TYPES).to include(wireguard_node_key: "wireguard-node-keys")
    end
  end

  describe "Phase N0 credential round-trip via Sdwan::ConstellationSigningKey holder" do
    # The constellation signing key uses the standard VaultCredential
    # concern via the Sdwan::ConstellationSigningKey holder model. In
    # test env Vault is disabled so storage falls through to the
    # encrypted DB column on the holder; in production the same call
    # path lands the bytes in Vault.
    let(:pub_b64)  { Base64.strict_encode64(SecureRandom.bytes(32)) }
    let(:priv_b64) { Base64.strict_encode64(SecureRandom.bytes(32)) }

    before do
      Sdwan::ConstellationSigningKey.where(account_id: account.id).delete_all
    end

    it "stores and retrieves the private key half via the holder model" do
      holder = Sdwan::ConstellationSigningKey.create!(
        account: account,
        handle: "acct-test-roundtrip",
        public_key_b64: pub_b64
      )
      holder.store_in_vault(
        private_key_b64: priv_b64,
        public_key_b64: pub_b64,
        algorithm: "ED25519"
      )
      # Re-fetch (not .reload) — the VaultCredential concern memoizes
      # @vault_credentials, and Rails' .reload doesn't clear instance
      # variables. find() returns a fresh instance with empty memo.
      fresh = Sdwan::ConstellationSigningKey.find(holder.id)

      expect(fresh.private_key_b64).to eq(priv_b64)
      expect(fresh.public_key_b64).to eq(pub_b64)
    end

    it "auto-clears credentials on holder destroy via VaultCredential cleanup hook" do
      holder = Sdwan::ConstellationSigningKey.create!(
        account: account,
        handle: "acct-test-destroy",
        public_key_b64: pub_b64
      )
      holder.store_in_vault(
        private_key_b64: priv_b64,
        public_key_b64: pub_b64,
        algorithm: "ED25519"
      )
      expect { holder.destroy! }.not_to raise_error
    end
  end
end
