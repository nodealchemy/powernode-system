# frozen_string_literal: true

module System
  # P9.2 — Per-peer audit log WORM shipment record.
  #
  # Each row represents one batch of FleetEvent rows older than 30
  # days that pertain to a specific federation peer, sealed into a
  # JSON-Lines export with a sha256 hash and content-addressable
  # `sealed_path`. The platform enforces the Social Contract #5
  # commitment by ensuring every peer's interactions have an
  # auditable trail beyond the hot-DB retention window.
  #
  # Status machine:
  #   pending  → sealed  → verified   (terminal)
  #              ↓
  #            failed                  (terminal, retryable next sweep)
  #
  # Plan reference: Decentralized Federation Architectural Fix 2 +
  # Social Contract commitment #5 + §I §L.
  class FederationAuditShipment < BaseRecord
    include System::Base

    STATUSES = %w[pending sealed verified failed].freeze
    TERMINAL_STATUSES = %w[verified failed].freeze

    self.table_name = "system_federation_audit_shipments"

    belongs_to :federation_peer, class_name: "System::FederationPeer"

    attribute :metadata, :jsonb, default: -> { {} }

    validates :period_start, :period_end, presence: true
    validates :status, inclusion: { in: STATUSES }
    validate  :period_end_after_start

    scope :pending,   -> { where(status: "pending") }
    scope :sealed,    -> { where(status: "sealed") }
    scope :verified,  -> { where(status: "verified") }
    scope :failed,    -> { where(status: "failed") }
    scope :terminal,  -> { where(status: TERMINAL_STATUSES) }

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    def mark_sealed!(sha256:, sealed_path:, event_count:)
      update!(
        status:      "sealed",
        sha256:      sha256,
        sealed_path: sealed_path,
        event_count: event_count,
        shipped_at:  Time.current
      )
    end

    def mark_verified!
      update!(status: "verified")
    end

    def mark_failed!(reason:)
      update!(status: "failed", error_message: reason.to_s[0, 1000])
    end

    private

    def period_end_after_start
      return if period_start.blank? || period_end.blank?
      errors.add(:period_end, "must be after period_start") unless period_end > period_start
    end
  end
end
