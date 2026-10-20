# frozen_string_literal: true

require "digest"
require "securerandom"

module System
  # Single-use enrollment token used during the mTLS bootstrap exchange.
  # Plaintext tokens are returned ONCE on create and never persisted; the DB
  # only stores SHA-256 hashes for verification at /node_api/enroll.
  #
  # Reference: Golden Eclipse M0.L (plan: node_api Contract + Security Architecture).
  class BootstrapToken < BaseRecord
    include System::Base

    # === Constants ===
    DEFAULT_TTL = 1.hour
    MAX_TTL = 7.days
    PLAINTEXT_BYTES = 32

    # Operator direction (IMP-cde9ee63c977 / memory:image-distribution-model):
    # operator-issued enrolment keys last 24h by default, 7d at most. Provider
    # seeds and netboot stay at the 1h DEFAULT_TTL.
    OPERATOR_KEY_DEFAULT_TTL = 24.hours

    # Purposes in use by the issuers (bootstrap_service/netboot, physical
    # enrollment, local_qemu cloud seed, proxmox enrollment seed, federation
    # acceptance) plus the design purposes. A nil purpose is legacy and allowed.
    PURPOSES = %w[
      operator_key
      cloud_seed
      netboot
      local_qemu_provision
      proxmox_uefi_provision
      physical_claim
      federation_managed_child_accept
    ].freeze

    DEFAULT_TTLS = { "operator_key" => OPERATOR_KEY_DEFAULT_TTL }.freeze
    # Multi-use is never permitted for new tokens; operator keys additionally
    # have an explicit single-use guarantee.
    SINGLE_USE_PURPOSES = %w[operator_key].freeze

    # === Associations ===
    belongs_to :node, class_name: "System::Node"
    belongs_to :node_instance, class_name: "System::NodeInstance", optional: true
    # Nullable: machine issuers (provider seeds, netboot, federation) have no user.
    belongs_to :created_by, class_name: "User", optional: true
    belongs_to :revoked_by, class_name: "User", optional: true

    # Account access through node
    delegate :account, to: :node
    delegate :account_id, to: :node

    # === Validations ===
    validates :token_hash,        presence: true, uniqueness: true
    validates :intended_subject,  presence: true
    validates :expires_at,        presence: true
    validates :purpose, inclusion: { in: PURPOSES }, allow_nil: true
    validate :single_use_only, on: :create
    validate :expiry_within_cap, on: :create

    # === Scopes ===
    scope :active,    -> { where(consumed_at: nil, revoked_at: nil).where("expires_at > ?", Time.current) }
    scope :consumed,  -> { where.not(consumed_at: nil) }
    scope :revoked,   -> { where.not(revoked_at: nil) }
    scope :expired,   -> { where(consumed_at: nil, revoked_at: nil).where("expires_at <= ?", Time.current) }

    # === Class API ===

    # Issues a fresh token bound to a node + intended_subject. Returns a tuple
    # [model, plaintext]. The plaintext is the value the agent presents in
    # cloud-init / iPXE; the DB only ever sees its SHA-256 hash.
    def self.issue!(node:, intended_subject:, node_instance: nil, ttl: nil,
                    single_use: true, purpose: nil, created_by: nil)
      ttl ||= default_ttl_for(purpose)
      if ttl > MAX_TTL
        raise ArgumentError, "ttl #{ttl.inspect} exceeds the maximum of #{MAX_TTL.inspect}"
      end

      plaintext = SecureRandom.urlsafe_base64(PLAINTEXT_BYTES)
      token = create!(
        node: node,
        node_instance: node_instance,
        token_hash: hash_for(plaintext),
        intended_subject: intended_subject,
        expires_at: ttl.from_now,
        single_use: single_use,
        purpose: purpose,
        created_by: created_by
      )
      token.send(:audit_hook, :issued)
      [ token, plaintext ]
    end

    def self.default_ttl_for(purpose)
      DEFAULT_TTLS.fetch(purpose.to_s, DEFAULT_TTL)
    end

    # Look up an active (non-consumed, non-revoked, non-expired) token by plaintext value.
    # Returns nil if not found / expired / consumed.
    def self.find_active_by_plaintext(plaintext)
      active.find_by(token_hash: hash_for(plaintext))
    end

    def self.hash_for(plaintext)
      Digest::SHA256.hexdigest(plaintext)
    end

    # === Instance API ===

    # The row lock makes consume and revoke mutually exclusive: a token revoked
    # after find_active_by_plaintext loaded it is refused here.
    def consume!(from_ip: nil)
      with_lock do
        raise InvalidConsumption, "token revoked"          if revoked?
        raise InvalidConsumption, "token already consumed" if consumed?
        raise InvalidConsumption, "token expired"          if expired?

        update!(consumed_at: Time.current, consumed_from_ip: from_ip)
      end
      audit_hook(:consumed)
      self
    end

    # Revokes an unconsumed token. Idempotent on an already-revoked token;
    # refuses a consumed one (nothing left to revoke). `by` is nil for machine
    # revocation.
    def revoke!(by: nil)
      newly_revoked = false
      with_lock do
        next if revoked?
        raise InvalidConsumption, "token already consumed" if consumed?

        update!(revoked_at: Time.current, revoked_by: by)
        newly_revoked = true
      end
      audit_hook(:revoked) if newly_revoked
      self
    end

    def revoked?
      revoked_at.present?
    end

    def consumed?
      consumed_at.present?
    end

    def expired?
      expires_at <= Time.current
    end

    def usable?
      !consumed? && !revoked? && !expired?
    end

    class InvalidConsumption < StandardError; end

    private

    # Hook point for the D3 AuditLog work: called after a successful :issued,
    # :consumed or :revoked transition. Deliberately a no-op here. Implementations
    # must NEVER log the plaintext or token_hash (record id, purpose, node and
    # actor only).
    def audit_hook(_event); end

    def single_use_only
      errors.add(:single_use, "must be true: multi-use enrolment tokens are not permitted") unless single_use
    end

    def expiry_within_cap
      return if expires_at.blank?

      errors.add(:expires_at, "exceeds the maximum TTL of #{MAX_TTL.inspect}") if expires_at > MAX_TTL.from_now + 1.minute
    end
  end
end
