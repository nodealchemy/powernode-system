# frozen_string_literal: true

# Per-constellation Ed25519 signing key. The private half lives in
# Vault (with encrypted DB fallback per the VaultCredential concern);
# the public half is column-stored. The MC signer uses the private
# key to seal each Sdwan::MembershipCredential envelope; the agent's
# mc_verifier uses the public key to validate them.
#
# In N0 there is one row per account (handle = "acct-<short-id>") so
# the model wire-shape matches what N2's Sdwan::Constellation will
# carry. When N2 lands, Sdwan::Constellation gains
# `belongs_to :signing_key, class_name: "Sdwan::ConstellationSigningKey"`
# and the signer's resolver swaps from "find by account+handle" to
# "find by constellation".
#
# Phase N0 of the in-house encrypted mesh overlay roadmap.
module Sdwan
  class ConstellationSigningKey < ApplicationRecord
    include VaultCredential

    self.table_name = "sdwan_constellation_signing_keys"
    self.vault_credential_type = "constellation_signing_key"

    belongs_to :account
    belongs_to :rotated_from, class_name: "Sdwan::ConstellationSigningKey", optional: true

    validates :handle, presence: true, uniqueness: { scope: :account_id }
    validates :public_key_b64, presence: true,
                               format: { with: /\A[A-Za-z0-9+\/]{43}=\z/, message: "must be a base64-encoded 32-byte key" }

    scope :active,  -> { where(revoked_at: nil) }
    scope :revoked, -> { where.not(revoked_at: nil) }

    def revoked?
      revoked_at.present?
    end

    def revoke!(reason: nil)
      return if revoked?

      update!(revoked_at: Time.current, revocation_reason: reason.to_s.presence)
    end

    # Returns the base64 private key half. Returns nil when revoked or
    # when no Vault entry exists. Mirrors Sdwan::PeerKey#private_key.
    def private_key_b64
      return nil if revoked?

      data = vault_credentials
      return nil unless data.is_a?(Hash)

      data[:private_key_b64] || data["private_key_b64"]
    end
  end
end
