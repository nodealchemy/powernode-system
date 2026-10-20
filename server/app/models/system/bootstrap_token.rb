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
    # Maximum lifetime per purpose. Operator-issued keys may live up to 7 days;
    # every platform-injected key (cloud seed, netboot, provider/federation/claim
    # seeds, legacy nil purpose) is capped at 1 hour.
    MAX_TTLS = { "operator_key" => 7.days }.freeze
    TTL_CAP_SLACK = 1.minute
    PLAINTEXT_BYTES = 32

    AUDITED_ACTIONS = %w[
      system.bootstrap_token.issued
      system.bootstrap_token.consumed
      system.bootstrap_token.revoked
    ].freeze

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
    # Create-only: a legacy row with a retired purpose must stay consumable/revocable.
    validates :purpose, inclusion: { in: PURPOSES }, allow_nil: true, on: :create
    validate :single_use_only, on: :create
    validate :expiry_within_cap, if: -> { new_record? || will_save_change_to_expires_at? }

    after_commit :flush_audit_events

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
      if ttl > max_ttl_for(purpose)
        raise ArgumentError, "ttl #{ttl.inspect} exceeds the maximum of #{max_ttl_for(purpose).inspect} for purpose #{purpose.inspect}"
      end

      plaintext = SecureRandom.urlsafe_base64(PLAINTEXT_BYTES)
      token = nil
      transaction do
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
        # Queued inside the transaction: delivered by after_commit, never on rollback.
        token.send(:queue_audit_event, :issued)
      end
      [ token, plaintext ]
    end

    def self.default_ttl_for(purpose)
      DEFAULT_TTLS.fetch(purpose.to_s, DEFAULT_TTL)
    end

    def self.max_ttl_for(purpose)
      MAX_TTLS.fetch(purpose.to_s, DEFAULT_TTL)
    end

    # Look up an active (non-consumed, non-revoked, non-expired) token by plaintext value.
    # Returns nil if not found / expired / consumed.
    def self.find_active_by_plaintext(plaintext, lock: false)
      scope = lock ? active.lock : active
      scope.find_by(token_hash: hash_for(plaintext))
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
        queue_audit_event(:consumed)
      end
      self
    end

    # Revokes an unconsumed token. Idempotent on an already-revoked token;
    # refuses a consumed one (nothing left to revoke). `by` is nil for machine
    # revocation.
    def revoke!(by: nil)
      with_lock do
        next if revoked?
        raise InvalidConsumption, "token already consumed" if consumed?

        update!(revoked_at: Time.current, revoked_by: by)
        queue_audit_event(:revoked)
      end
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

    # Events (:issued, :consumed, :revoked) are queued when the transition is
    # made and delivered to #audit_hook only AFTER COMMIT, so a rolled-back
    # enrolment never writes an audit row. One AuditLog row per event, through
    # the core AuditLog.log_action seam (same as System::LifecycleAuditable).
    #
    # FAIL-OPEN, matching that house pattern for lifecycle audits: a failed audit
    # write is logged and swallowed so it can never block enrolment. The log line
    # carries the token id and the error class/message only. The row and the log
    # NEVER include the plaintext or token_hash.
    def audit_hook(event)
      return unless account.present?

      actor = event == :revoked ? revoked_by : (event == :issued ? created_by : nil)
      ::AuditLog.transaction(requires_new: true) do
        ::AuditLog.log_action(
          action: "system.bootstrap_token.#{event}",
          resource: self,
          user: actor,
          account: account,
          ip_address: event == :consumed ? consumed_from_ip : nil,
          source: "system",
          metadata: audit_metadata(event, actor)
        )
      end
    rescue StandardError => e
      Rails.logger.error(
        "[System::BootstrapToken] audit write failed for token #{id} #{event}: #{e.class}: #{e.message}"
      )
    end

    def audit_metadata(event, actor)
      {
        token_id: id,
        purpose: purpose,
        node_id: node_id,
        node_instance_id: node_instance_id,
        expires_at: expires_at&.iso8601(3),
        actor_type: actor ? "user" : "system",
        actor_id: actor&.id,
        consumed_from_ip: (consumed_from_ip.to_s if event == :consumed)
      }.compact
    end

    def queue_audit_event(event)
      # Always called inside the transaction making the transition; the
      # after_commit callback delivers it.
      (@pending_audit_events ||= []) << event
    end

    def flush_audit_events
      events, @pending_audit_events = @pending_audit_events, nil
      events&.each { |event| audit_hook(event) }
    end

    def single_use_only
      errors.add(:single_use, "must be true: multi-use enrolment tokens are not permitted") unless single_use
    end

    def expiry_within_cap
      return if expires_at.blank?

      cap = self.class.max_ttl_for(purpose)
      return if expires_at <= (created_at || Time.current) + cap + TTL_CAP_SLACK

      errors.add(:expires_at, "exceeds the maximum TTL of #{cap.inspect} for purpose #{purpose.inspect}")
    end
  end
end
