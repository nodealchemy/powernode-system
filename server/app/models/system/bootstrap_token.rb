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
      system.bootstrap_token.revealed
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

    # Purposes whose plaintext is kept SEALED so a gated reveal can recover it
    # (IMP-5c6a03c3b335). Every other purpose is returned once at mint and never
    # recoverable.
    SEALED_PURPOSES = %w[operator_key].freeze

    # ActiveRecord::Encryption (the house keys): ciphertext at rest, filtered out
    # of #inspect and the logs. Purged (nil) on consume! and revoke!.
    encrypts :sealed_plaintext

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
        # ONE usable operator key per instance: minting a new one revokes any
        # earlier unconsumed key for it (audited, sealed copy purged), so an old
        # key can never be recovered or redeemed alongside the new one.
        #
        # LOCK ORDER (everywhere): instance row first, then token rows in id
        # order. Mint takes it here; NodeEnrollmentService#enroll! locks the
        # instance before the token it consumes, and consume! then takes the
        # sibling rows with open_for_instance (ORDER BY id). One order cannot
        # deadlock; enroll! also rescues ActiveRecord::Deadlocked as a safety net.
        # The re-check under the instance lock closes the window between the
        # caller's guard and this insert: an instance that enrolled meanwhile
        # refuses the mint. The partial unique index is the final backstop.
        if SEALED_PURPOSES.include?(purpose.to_s) && node_instance
          node_instance.lock!
          if (why = instance_refusal(node_instance))
            raise InstanceNotAvailable, why
          end

          open_for_instance(node_instance.id, purpose: purpose.to_s).each { |prior| prior.revoke!(by: created_by) }
        end
        token = create!(
          node: node,
          node_instance: node_instance,
          token_hash: hash_for(plaintext),
          intended_subject: intended_subject,
          expires_at: ttl.from_now,
          single_use: single_use,
          purpose: purpose,
          created_by: created_by,
          sealed_plaintext: (plaintext if SEALED_PURPOSES.include?(purpose.to_s))
        )
        token.send(:write_audit!, :issued)
        # Optional in-transaction hook (e.g. rendering a provisioning document
        # from the plaintext): anything it raises rolls the mint AND its audit
        # row back together, so no orphan key is left behind.
        yield(token, plaintext) if block_given?
      end
      [ token, plaintext ]
    rescue ActiveRecord::RecordNotUnique
      # Lost a concurrent mint for the same instance (one open operator key per
      # instance, enforced by a partial unique index). Static message.
      raise InstanceNotAvailable, "another key was issued for this instance at the same time"
    end

    # Unconsumed, unrevoked keys bound to an instance (expired ones included:
    # their sealed copy must die too). Locked, so concurrent mint/consume
    # serialise on the same rows.
    def self.open_for_instance(node_instance_id, purpose: nil)
      scope = where(node_instance_id: node_instance_id, consumed_at: nil, revoked_at: nil)
      scope = scope.where(purpose: purpose) if purpose
      scope.order(:id).lock.to_a
    end

    # Why a key cannot be issued for, or revealed on, this instance - or nil.
    # Once a device has claimed it, it is running, finished, errored or already
    # holds an mTLS identity, a key could only invite a second device to try.
    CLOSED_INSTANCE_STATUSES = %w[running terminated error].freeze
    def self.instance_refusal(instance)
      return "this instance has already been claimed by a device" if instance.claimed?
      return "this instance has already enrolled" if instance.mtls_subject.present?
      if CLOSED_INSTANCE_STATUSES.include?(instance.status)
        return "this instance is #{instance.status}"
      end

      nil
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

        update!(consumed_at: Time.current, consumed_from_ip: from_ip, sealed_plaintext: nil)
        write_audit!(:consumed)
        # This key enrolled the instance, so every other open key bound to it
        # (any purpose) is dead: revoked and audited in this same transaction.
        if node_instance_id
          self.class.open_for_instance(node_instance_id).reject { |t| t.id == id }.each { |t| t.revoke!(by: nil) }
        end
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

        update!(revoked_at: Time.current, revoked_by: by, sealed_plaintext: nil)
        write_audit!(:revoked)
      end
      self
    end

    # Returns the plaintext of an UNCONSUMED, UNREVOKED, UNEXPIRED operator key
    # from its sealed copy. The `revealed` audit row is written INSIDE the lock
    # and FAILS CLOSED: if it cannot be written nothing is returned. The row
    # names the actor and the token, never the plaintext. `by` MUST be the User whose
    # own-session approval released it (the verb is human-only).
    def reveal!(by:)
      raise ArgumentError, "reveal! requires the approving User" unless by.is_a?(::User)

      plaintext = nil
      with_lock do
        raise NotRevealable, "token revoked"          if revoked?
        raise NotRevealable, "token already consumed" if consumed?
        raise NotRevealable, "token expired"          if expired?
        if node_instance && (why = self.class.instance_refusal(node_instance))
          raise NotRevealable, why
        end

        plaintext = sealed_plaintext.presence
        raise NotRevealable, "no recoverable copy of this key" if plaintext.nil?

        write_audit!(:revealed, actor: by)
      end
      plaintext
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
    # The key cannot be revealed: not an operator key, no sealed copy, or no
    # longer usable. The message is static and carries no token material.
    class NotRevealable < StandardError; end
    # A key cannot be issued for this instance right now: it is claimed,
    # enrolled, running or finished, or another mint won the race. Static message.
    class InstanceNotAvailable < StandardError; end
    # The audit row for a key operation could not be written. Key operations
    # FAIL CLOSED: the surrounding transaction rolls back. The message is static
    # (no token material, no underlying error text).
    class AuditFailure < StandardError; end

    private

    # Writes the AuditLog row for a key operation INSIDE the operation's own
    # transaction (core AuditLog.log_action seam, as System::LifecycleAuditable).
    # FAIL CLOSED by operator decision: there is no rescue-and-continue; a failed
    # write raises AuditFailure, rolling the issue/consume/revoke (and any
    # enclosing enrolment) back. A rollback therefore also leaves no audit row.
    # The row NEVER includes the plaintext or token_hash.
    def write_audit!(event, actor: nil)
      actor ||= { revoked: revoked_by, issued: created_by }[event]
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
    rescue StandardError
      raise AuditFailure, "bootstrap token audit write failed"
    end

    def audit_metadata(event, actor)
      {
        purpose: purpose,
        node_id: node_id,
        node_instance_id: node_instance_id,
        expires_at: expires_at&.iso8601(3),
        actor_type: actor ? "user" : "system",
        actor_id: actor&.id,
        consumed_from_ip: (consumed_from_ip.to_s if event == :consumed)
      }.compact
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
