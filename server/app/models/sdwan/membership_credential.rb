# frozen_string_literal: true

# Time-bounded membership credential issued by the platform controller
# (the Rails app) to an Sdwan::Peer. Sealed by the constellation's
# Ed25519 signing key. The agent's mc_verifier validates the signature
# + window on every reconcile and refuses forwarding when the active MC
# is missing, expired, or signed by an unknown constellation.
#
# Lifecycle (AASM):
#
#   pending   → active     (issue!)
#   active    → expiring   (mark_expiring; refresh_after crossed)
#   active    → revoked    (revoke!)
#   expiring  → active     (re-issue; previous row keeps its history,
#                           a new row supersedes it via revision++)
#   expiring  → revoked    (revoke!)
#
# Revocation is by withholding refresh — there is no CRL on the wire.
# Once `not_after` passes the agent stops forwarding for the (peer,
# network) pair until a fresh MC arrives.
#
# Phase N0 of the in-house encrypted mesh overlay roadmap.
module Sdwan
  class MembershipCredential < ApplicationRecord
    include AASM

    self.table_name = "sdwan_membership_credentials"

    STATUSES = %w[pending active expiring revoked].freeze

    belongs_to :account
    belongs_to :peer,    class_name: "Sdwan::Peer",    foreign_key: :sdwan_peer_id
    belongs_to :network, class_name: "Sdwan::Network", foreign_key: :sdwan_network_id

    validates :status,                inclusion: { in: STATUSES }
    validates :revision,              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :issued_at,             presence: true
    validates :not_before,            presence: true
    validates :not_after,             presence: true
    validates :refresh_after,         presence: true
    validates :envelope_json,         presence: true
    validates :signature_b64,         presence: true
    validates :constellation_handle,  presence: true

    validate :not_after_must_be_after_not_before
    validate :refresh_after_must_be_within_window

    scope :active_status,  -> { where(status: "active") }
    scope :expiring,       -> { where(status: "expiring") }
    scope :revoked,        -> { where(status: "revoked") }
    scope :live,           -> { where(status: %w[active expiring]) }
    # Refresh window: not yet expired, but past the refresh_after boundary.
    # The agent watches this scope to know when to ask for a new MC.
    scope :due_for_refresh, lambda { |now: Time.current|
      where(status: %w[active expiring]).where("refresh_after <= ?", now)
    }
    # Sensor surface: live but inside `window` of expiry.
    scope :expiring_within, lambda { |window, now: Time.current|
      where(status: %w[active expiring]).where("not_after <= ?", now + window)
    }

    aasm column: :status, whiny_transitions: false do
      state :pending, initial: true
      state :active
      state :expiring
      state :revoked

      event :issue do
        transitions from: %i[pending], to: :active
      end

      event :mark_expiring do
        transitions from: :active, to: :expiring
      end

      event :supersede do
        # The old row stays around as audit history; this event is the
        # explicit "no longer the active MC" transition. Distinct from
        # :revoke! so dashboards can show "rotated" vs "revoked" cleanly.
        transitions from: %i[active expiring], to: :revoked
        before { |reason: nil| self.revoked_at = Time.current; self.revocation_reason = (reason || "superseded").to_s }
      end

      event :revoke do
        transitions from: %i[pending active expiring], to: :revoked
        before { |reason: nil| self.revoked_at = Time.current; self.revocation_reason = (reason || "withheld").to_s }
      end
    end

    # True if the MC is within its time window AND in a live status.
    # The agent's verifier uses this on every reconcile.
    def usable?(now: Time.current)
      %w[active expiring].include?(status) && now >= not_before && now < not_after
    end

    # True if the MC has crossed its refresh boundary. Drives the
    # agent-side refresh-before-expiry loop.
    def refresh_due?(now: Time.current)
      now >= refresh_after && now < not_after && %w[active expiring].include?(status)
    end

    # Convenience: total seconds remaining before hard expiry.
    def seconds_until_expiry(now: Time.current)
      [(not_after - now).to_i, 0].max
    end

    # The signed envelope as parsed JSON. Useful for tests and operator
    # tools — the agent receives this verbatim and re-parses it itself.
    def envelope
      JSON.parse(envelope_json)
    rescue JSON::ParserError
      {}
    end

    # Wire envelope embedded in the per-peer config push. Mirrors the
    # spec in plan §4.2 — the agent's mc_verifier consumes exactly
    # this shape.
    def to_wire
      {
        envelope: envelope_json,
        signature: signature_b64,
        constellation_handle: constellation_handle,
        revision: revision,
        not_before: not_before.utc.iso8601,
        not_after: not_after.utc.iso8601,
        refresh_after: refresh_after.utc.iso8601
      }
    end

    private

    def not_after_must_be_after_not_before
      return if not_before.blank? || not_after.blank?

      errors.add(:not_after, "must be after not_before") if not_after <= not_before
    end

    def refresh_after_must_be_within_window
      return if refresh_after.blank? || not_before.blank? || not_after.blank?

      if refresh_after < not_before
        errors.add(:refresh_after, "must be on or after not_before")
      elsif refresh_after > not_after
        errors.add(:refresh_after, "must be on or before not_after")
      end
    end
  end
end
