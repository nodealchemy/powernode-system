# frozen_string_literal: true

module System
  # AI/MCP workload substrate L2.5 (A2A) — per-account Ed25519 signing key for
  # peer capability tokens. The private half lives in Vault (encrypted DB
  # fallback via the VaultCredential concern); the public half is column-stored
  # and advertised to agents so they can verify token signatures OFFLINE.
  #
  # Mirrors Sdwan::ConstellationSigningKey, but is a DISTINCT key — capability
  # tokens and SDWAN membership credentials are different security domains and
  # never share signing material.
  class PeerCapabilitySigningKey < BaseRecord
    include System::Base
    include VaultCredential

    self.table_name = "system_peer_capability_signing_keys"
    self.vault_credential_type = "peer_capability_signing_key"

    belongs_to :account
    belongs_to :rotated_from, class_name: "System::PeerCapabilitySigningKey", optional: true

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

    # Base64 private key half from Vault (nil when revoked / no entry).
    def private_key_b64
      return nil if revoked?

      data = vault_credentials
      return nil unless data.is_a?(Hash)

      data[:private_key_b64] || data["private_key_b64"]
    end
  end
end
