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
    PLAINTEXT_BYTES = 32

    # === Associations ===
    belongs_to :node, class_name: "System::Node"
    belongs_to :node_instance, class_name: "System::NodeInstance", optional: true

    # Account access through node
    delegate :account, to: :node
    delegate :account_id, to: :node

    # === Validations ===
    validates :token_hash,        presence: true, uniqueness: true
    validates :intended_subject,  presence: true
    validates :expires_at,        presence: true

    # === Scopes ===
    scope :active,    -> { where(consumed_at: nil).where("expires_at > ?", Time.current) }
    scope :consumed,  -> { where.not(consumed_at: nil) }
    scope :expired,   -> { where(consumed_at: nil).where("expires_at <= ?", Time.current) }

    # === Class API ===

    # Issues a fresh token bound to a node + intended_subject. Returns a tuple
    # [model, plaintext]. The plaintext is the value the agent presents in
    # cloud-init / iPXE; the DB only ever sees its SHA-256 hash.
    def self.issue!(node:, intended_subject:, node_instance: nil, ttl: DEFAULT_TTL,
                    single_use: true, purpose: nil)
      plaintext = SecureRandom.urlsafe_base64(PLAINTEXT_BYTES)
      token = create!(
        node: node,
        node_instance: node_instance,
        token_hash: hash_for(plaintext),
        intended_subject: intended_subject,
        expires_at: ttl.from_now,
        single_use: single_use,
        purpose: purpose
      )
      [ token, plaintext ]
    end

    # Look up an active (non-consumed, non-expired) token by plaintext value.
    # Returns nil if not found / expired / consumed.
    def self.find_active_by_plaintext(plaintext)
      active.find_by(token_hash: hash_for(plaintext))
    end

    def self.hash_for(plaintext)
      Digest::SHA256.hexdigest(plaintext)
    end

    # === Instance API ===

    def consume!(from_ip: nil)
      raise InvalidConsumption, "token already consumed" if consumed?
      raise InvalidConsumption, "token expired"           if expired?

      update!(consumed_at: Time.current, consumed_from_ip: from_ip)
    end

    def consumed?
      consumed_at.present?
    end

    def expired?
      expires_at <= Time.current
    end

    def usable?
      !consumed? && !expired?
    end

    class InvalidConsumption < StandardError; end
  end
end
