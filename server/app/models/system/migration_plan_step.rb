# frozen_string_literal: true

module System
  # One step in a Migration's plan — represents a single record action.
  # Steps are applied in ascending step_order; each step records its own
  # success/failure independently so a failed migration can be inspected
  # at the per-step level.
  #
  # Plan reference: Decentralized Federation §F + P5.3.
  class MigrationPlanStep < BaseRecord
    ACTIONS = %w[create link_local skip conflict].freeze
    CONFLICT_POLICIES = %w[skip_if_exists rename_with_suffix overwrite fail].freeze

    self.table_name = "system_migration_plan_steps"

    belongs_to :migration, class_name: "System::Migration"

    # MigrationPlanStep accounts inherit through the Migration. The
    # System::Base concern's `belongs_to :account` doesn't fit cleanly
    # here because the join carries no own account_id column.
    delegate :account, :account_id, to: :migration

    attribute :payload,  :jsonb, default: -> { {} }
    attribute :metadata, :jsonb, default: -> { {} }

    validates :step_order,     presence: true,
                               numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :resource_kind,  presence: true, length: { maximum: 64 }
    validates :resource_id,    presence: true
    validates :action,          inclusion: { in: ACTIONS }
    validates :conflict_policy, inclusion: { in: CONFLICT_POLICIES }

    scope :ordered, -> { order(:step_order) }
    scope :pending, -> { where(applied_at: nil) }
    scope :applied, -> { where.not(applied_at: nil) }
    scope :by_kind, ->(kind) { where(resource_kind: kind) }

    def applied?
      applied_at.present?
    end

    def mark_applied!(at: Time.current)
      update!(applied_at: at, error_message: nil)
    end

    def mark_failed!(message)
      update!(error_message: message.to_s[0, 2000])
    end
  end
end
