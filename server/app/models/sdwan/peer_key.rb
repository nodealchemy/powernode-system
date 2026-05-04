# frozen_string_literal: true

# Per-peer WireGuard keypair record. Public key is column-stored (it isn't
# secret); private key lives Vault-first via the VaultCredential concern at
# vault_credential_type "wireguard_node_key", with encrypted DB fallback.
#
# Rotation creates a new row whose rotated_from_id chains back to the
# previous one. The `idx_sdwan_peer_keys_one_active_per_peer` partial unique
# index ensures only one un-revoked key exists per peer at any time.
#
# Slice 1 of the SDWAN plan.
module Sdwan
  class PeerKey < ApplicationRecord
    self.table_name = "sdwan_peer_keys"

    include VaultCredential

    self.vault_credential_type = "wireguard_node_key"

    belongs_to :peer, class_name: "Sdwan::Peer", foreign_key: :sdwan_peer_id
    belongs_to :rotated_from, class_name: "Sdwan::PeerKey", optional: true

    delegate :account_id, to: :peer

    validates :public_key, presence: true, uniqueness: true,
                           length: { is: 44 },
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

    # Convenience accessor — VaultCredential#vault_credentials returns the
    # full hash {public_key:, private_key:}; callers usually want just the
    # private half. Returns nil when the row is revoked or Vault has no
    # entry for it.
    def private_key
      return nil if revoked?

      data = vault_credentials
      data.is_a?(Hash) ? (data[:private_key] || data["private_key"]) : nil
    end
  end
end
