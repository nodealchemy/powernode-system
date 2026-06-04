# frozen_string_literal: true

module System
  module Fleet
    # Ground-truth effectiveness record for an autonomous remediation (substrate
    # self-improvement, Phase 0 — the validate step).
    #
    # When the fleet autonomy loop PROCEEDs an action for a signal, it records a
    # pending outcome keyed by the signal's fingerprint. A later tick re-senses:
    # if the fingerprint is gone the remediation was EFFECTIVE; if it still fires
    # it was INEFFECTIVE. This is the ground truth the LEARN/ADAPT steps (later
    # phases) consume — you can't improve on actions you never measured.
    class RemediationOutcome < BaseRecord
      self.table_name = "system_fleet_remediation_outcomes"

      STATUSES = %w[pending effective ineffective inconclusive].freeze

      belongs_to :account

      validates :signal_kind, :fingerprint, :acted_at, :settle_until, presence: true
      validates :status, inclusion: { in: STATUSES }

      attribute :metadata, :jsonb, default: -> { {} }

      scope :pending,   -> { where(status: "pending") }
      scope :effective, -> { where(status: "effective") }
      scope :due,       -> { pending.where(settle_until: ..Time.current) }

      def effective?   = status == "effective"
      def ineffective? = status == "ineffective"

      # Score for the LEARN step: effective -> 1.0, ineffective -> 0.0, else nil
      # (pending/inconclusive carry no signal yet).
      def effectiveness_score
        case status
        when "effective" then 1.0
        when "ineffective" then 0.0
        end
      end
    end
  end
end
