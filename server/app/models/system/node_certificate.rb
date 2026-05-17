# frozen_string_literal: true

module System
  # mTLS certificate issued by the platform's internal CA (Vault PKI) for a
  # NodeInstance. The PEM chain is stored Vault-first (per VaultCredential
  # concern) with an encrypted DB fallback when Vault is unavailable.
  #
  # Reference: Golden Eclipse M0.L; project_credential_pattern.md memory.
  class NodeCertificate < BaseRecord
    include System::Base
    include VaultCredential

    self.vault_credential_type = "node_pki"

    # === Constants ===
    ROTATE_THRESHOLD_RATIO = 0.75 # rotate at 75% of TTL
    EXPIRY_WARN_DAYS       = 7

    # === Associations ===
    # node_instance is optional for federation_peer certs (subject_kind="federation_peer")
    # which represent a remote Powernode platform, not an on-node agent.
    # An explicit account_id column was added (P3 plan) so federation-peer
    # certs can resolve their owning account without going through an
    # instance that doesn't exist for them.
    belongs_to :node_instance, class_name: "System::NodeInstance", optional: true
    delegate :node, to: :node_instance, allow_nil: true

    # Account resolution: direct association wins when present; falls back
    # to node_instance.account for the legacy/instance-cert path so existing
    # callers continue to work.
    def account
      return ::Account.find_by(id: account_id) if account_id
      node_instance&.account
    end

    def account_id
      self[:account_id] || node_instance&.account_id
    end

    # === Validations ===
    validates :serial,     presence: true, uniqueness: true
    validates :subject,    presence: true
    validates :not_before, presence: true
    validates :not_after,  presence: true
    validate  :validity_window

    # === Scopes ===
    scope :active,         -> { where(revoked_at: nil).where("not_after > ?", Time.current) }
    scope :revoked,        -> { where.not(revoked_at: nil) }
    scope :expired,        -> { where(revoked_at: nil).where("not_after <= ?", Time.current) }
    scope :expiring_soon,  -> { active.where("not_after <= ?", EXPIRY_WARN_DAYS.days.from_now) }

    # === Lifecycle ===

    # Total seconds in this cert's validity window.
    def lifetime_seconds
      (not_after - not_before).to_i
    end

    # Seconds remaining until expiry (negative if expired).
    def remaining_seconds
      (not_after - Time.current).to_i
    end

    # True when at least ROTATE_THRESHOLD_RATIO of the lifetime has elapsed.
    def due_for_rotation?
      return false if revoked?

      elapsed = (Time.current - not_before).to_i
      elapsed >= (lifetime_seconds * ROTATE_THRESHOLD_RATIO)
    end

    def revoke!(reason:)
      raise AlreadyRevoked, "certificate #{serial} already revoked" if revoked?

      update!(revoked_at: Time.current, revocation_reason: reason.to_s)
    end

    def revoked?
      revoked_at.present?
    end

    def expired?
      not_after <= Time.current
    end

    def active?
      !revoked? && !expired?
    end

    def days_until_expiry
      ((not_after - Time.current) / 1.day).to_i
    end

    private

    def validity_window
      return if not_before.nil? || not_after.nil?

      errors.add(:not_after, "must be after not_before") if not_after <= not_before
    end

    class AlreadyRevoked < StandardError; end
  end
end
