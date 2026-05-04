# frozen_string_literal: true

# A single WireGuard client config issued to a user. The public key is
# column-stored (not secret); the private key is Vault-first via the
# VaultCredential concern at type "wireguard_user_key". Address is
# deterministically derived from device.id so operators can reverse-resolve
# from a packet capture without DB joins.
#
# Lifecycle:
#   created → pending download (last_downloaded_at: nil)
#           → downloaded (last_downloaded_at: <ts>)  [bootstrap URL is now 410]
#           → revoked    (revoked_at: <ts>)          [compiler drops from hub view]
#
# Slice 4 of the SDWAN plan.
module Sdwan
  class UserDevice < ApplicationRecord
    self.table_name = "sdwan_user_devices"

    include VaultCredential

    self.vault_credential_type = "wireguard_user_key"

    belongs_to :access_grant, class_name: "Sdwan::AccessGrant", foreign_key: :sdwan_access_grant_id

    delegate :network,    to: :access_grant
    delegate :account,    to: :access_grant
    delegate :account_id, to: :access_grant
    delegate :user,       to: :access_grant

    validates :label, presence: true, length: { maximum: 64 },
                      uniqueness: { scope: :sdwan_access_grant_id }
    validates :public_key, presence: true, uniqueness: true,
                           length: { is: 44 },
                           format: { with: /\A[A-Za-z0-9+\/]{43}=\z/, message: "must be a base64-encoded 32-byte key" }
    validates :assigned_address, presence: true, uniqueness: true

    before_validation :allocate_host_address, on: :create

    scope :active,    -> { where(revoked_at: nil) }
    scope :revoked,   -> { where.not(revoked_at: nil) }
    scope :downloaded, -> { where.not(last_downloaded_at: nil) }
    scope :pending_download, -> { where(last_downloaded_at: nil, revoked_at: nil) }

    def revoked?
      revoked_at.present?
    end

    def downloadable?
      !revoked? && last_downloaded_at.nil? && access_grant.active?
    end

    def revoke!(reason: nil)
      return if revoked?

      update!(revoked_at: Time.current, revocation_reason: reason.to_s.presence)
    end

    # Marks the bootstrap URL as consumed. Single-use semantics: the
    # second fetch returns 410 Gone. Operator-driven re-issuance creates
    # a new UserDevice (with a fresh keypair) rather than re-arming the
    # download — so credential history is auditable.
    def mark_downloaded!
      update_columns(last_downloaded_at: Time.current, updated_at: Time.current)
    end

    # Returns the X25519 private key bytes (base64), or nil if revoked /
    # no Vault entry. Read once at bootstrap time then never again — the
    # config is rendered, the value is dropped from process memory.
    def private_key_b64
      return nil if revoked?

      data = vault_credentials
      data.is_a?(Hash) ? (data[:private_key] || data["private_key"]) : nil
    end

    private

    def allocate_host_address
      return if assigned_address.present?
      return if sdwan_access_grant_id.blank?

      self.id ||= UUID7.generate
      net = network
      return unless net

      self.assigned_address = ::Sdwan::PrefixAllocator.allocate_peer_address!(network: net, peer_id: id)
    end
  end
end
