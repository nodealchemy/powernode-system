# frozen_string_literal: true

module System
  # A physical device that has polled /api/v1/system/node_api/claim but
  # hasn't yet been bound to a NodeInstance by an operator. The claim
  # flow uses (account_id, discovered_mac) as the upsert key — repeat
  # polls update last_seen_at and refresh expires_at without minting
  # new claim_codes.
  #
  # The claim_code is an 8-character string drawn from a glyph-disjoint
  # alphabet (omits I, L, O, 0, 1) so an operator can read it off a Pi's
  # HDMI console without ambiguity. The keyspace is ~10^11; collisions
  # within the 24h active window are negligible.
  #
  # Lifecycle:
  #   1. Device polls /claim (no operator action) → row created or updated
  #   2. Operator confirms claim via UnclaimedDevicesController#claim
  #      → claimed_node_instance set, BootstrapToken issued
  #   3. Device polls /claim again → response carries the bootstrap token
  #   4. Reaper job deletes rows past expires_at (default 24h)
  #
  # Reference: docs/plans/wondrous-yawning-anchor.md.
  class UnclaimedDevice < BaseRecord
    include System::Base

    # Glyph-disjoint alphabet (no I/L/O/0/1, no 5/S confusion).
    CLAIM_CODE_ALPHABET = %w[A B C D E F G H J K M N P Q R S T U V W X Y Z 2 3 4 6 7 8 9].freeze
    CLAIM_CODE_LENGTH   = 8
    DEFAULT_TTL         = 24.hours

    belongs_to :account
    belongs_to :claimed_node_instance,
               class_name: "System::NodeInstance",
               optional: true

    validates :claim_code, presence: true, uniqueness: true
    validates :first_seen_at, :last_seen_at, :expires_at, presence: true

    scope :active,    -> { where("expires_at > ?", Time.current).where(claimed_at: nil) }
    scope :expired,   -> { where("expires_at <= ?", Time.current) }
    scope :unclaimed, -> { where(claimed_at: nil) }
    scope :claimed,   -> { where.not(claimed_at: nil) }

    # Returns true if this device has been bound to a NodeInstance and the
    # operator has confirmed identity. Subsequent /claim polls will receive
    # the bootstrap token in the response.
    def claimed?
      claimed_at.present? && claimed_node_instance_id.present?
    end

    # Generates a fresh claim_code drawn from the glyph-disjoint alphabet.
    # Retries on the very rare uniqueness collision (1-in-10^11 odds).
    def self.generate_claim_code
      loop do
        candidate = Array.new(CLAIM_CODE_LENGTH) { CLAIM_CODE_ALPHABET.sample }.join
        return candidate unless exists?(claim_code: candidate)
      end
    end
  end
end
