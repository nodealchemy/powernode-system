# frozen_string_literal: true

module System
  # Peer record for a NodeInstance that has self-announced as an agent peer.
  # Stores declared capabilities, skills, addresses, and execution stats.
  # Operator-activation-gated: peers start `enabled: false` to prevent
  # accidental capability disclosure; operator activation is required
  # before remote-task delegation.
  #
  # Reference: comprehensive stabilization sweep P6; Golden Eclipse F-3.
  class NodeInstancePeer < BaseRecord
    include System::Base

    STATUSES = %w[registered active degraded disconnected].freeze

    belongs_to :node_instance, class_name: "System::NodeInstance"
    belongs_to :account

    delegate :node, to: :node_instance

    validates :handle, presence: true, length: { maximum: 64 },
                       uniqueness: { scope: :account_id }
    validates :status, inclusion: { in: STATUSES }
    validates :trust_score, numericality: { greater_than_or_equal_to: 0,
                                            less_than_or_equal_to: 1 }
    validates :daily_decision_budget,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    scope :enabled,    -> { where(enabled: true) }
    scope :active,     -> { where(status: "active") }
    scope :online,     -> { where(status: %w[active degraded]) }
    scope :for_handle, ->(handle) { where(handle: handle) }

    # Atomically increment execution counters and last_executed_at.
    def record_execution!(success:)
      self.class.where(id: id).update_all([
        "execution_count = COALESCE(execution_count,0) + 1, " \
        "execution_failure_count = COALESCE(execution_failure_count,0) + ?, " \
        "last_executed_at = NOW(), updated_at = NOW(), " \
        "trust_score = LEAST(1.0, GREATEST(0.0, COALESCE(trust_score, 0.5) + ?))",
        success ? 0 : 1,
        success ? 0.005 : -0.02
      ])
      reload
    end

    # Atomically increment daily decision counter, rolling the window if needed.
    # Returns true if the increment fits in the budget; false if exceeded.
    def reserve_decision!
      transaction do
        lock!
        rollover_window if window_stale?

        if daily_decision_used >= daily_decision_budget
          return false
        end

        update!(daily_decision_used: daily_decision_used + 1)
        true
      end
    end

    def addresses_array
      Array(addresses)
    end

    private

    def rollover_window
      return if daily_decision_window_start.present? &&
                daily_decision_window_start >= 24.hours.ago

      assign_attributes(
        daily_decision_window_start: Time.current,
        daily_decision_used: 0
      )
    end

    def window_stale?
      daily_decision_window_start.blank? || daily_decision_window_start < 24.hours.ago
    end
  end
end
