# frozen_string_literal: true

module System
  # A cross-peer resource transfer operation. Two variants:
  #   - duplicate: copy record(s) to destination; both peers retain
  #   - migrate:   move record(s) to destination; source deletes after destination ACKs
  #
  # State machine:
  #   planned → validating → (conflict) → transferring → applying → completed
  #                                                              ↘ failed
  #                                                              ↘ cancelled
  #
  # Plan reference: Decentralized Federation §F + P5.3.
  class Migration < BaseRecord
    include System::Base

    OPERATIONS = %w[duplicate migrate].freeze
    STATUSES   = %w[planned validating transferring conflict applying completed failed cancelled].freeze

    TERMINAL_STATUSES = %w[completed failed cancelled].freeze

    # Allowed transitions. Conflict is a side-state — caller can retry
    # after resolving conflicts (back to validating) or fail outright.
    TRANSITIONS = {
      "planned"      => %w[validating cancelled],
      "validating"   => %w[transferring conflict cancelled failed],
      "conflict"     => %w[validating cancelled failed],
      "transferring" => %w[applying failed cancelled],
      "applying"     => %w[completed failed],
      "completed"    => [],
      "failed"       => [],
      "cancelled"    => []
    }.freeze

    self.table_name = "system_migrations"

    belongs_to :destination_peer,
               class_name: "System::FederationPeer",
               optional: true
    belongs_to :initiated_by_user,
               class_name: "User",
               optional: true

    has_many :plan_steps,
             class_name: "System::MigrationPlanStep",
             dependent: :destroy

    attribute :plan_summary, :jsonb, default: -> { {} }
    attribute :conflict_log, :jsonb, default: -> { [] }
    attribute :audit_log,    :jsonb, default: -> { [] }
    attribute :metadata,     :jsonb, default: -> { {} }

    validates :operation, inclusion: { in: OPERATIONS }
    validates :status,    inclusion: { in: STATUSES }
    validates :root_resource_kind, presence: true, length: { maximum: 64 }
    validates :root_resource_id,   presence: true

    scope :active,    -> { where.not(status: TERMINAL_STATUSES) }
    scope :terminal,  -> { where(status: TERMINAL_STATUSES) }
    scope :completed, -> { where(status: "completed") }
    scope :failed,    -> { where(status: "failed") }
    scope :duplicates, -> { where(operation: "duplicate") }
    scope :migrates,   -> { where(operation: "migrate") }

    def can_transition_to?(target)
      TRANSITIONS.fetch(status, []).include?(target.to_s)
    end

    def transition_to!(target, error_message: nil, audit_entry: nil)
      return false unless can_transition_to?(target)

      attrs = { status: target.to_s }
      attrs[:started_at]    = Time.current if target.to_s == "transferring" && started_at.nil?
      attrs[:completed_at]  = Time.current if target.to_s == "completed"
      attrs[:failed_at]     = Time.current if target.to_s == "failed"
      attrs[:cancelled_at]  = Time.current if target.to_s == "cancelled"
      attrs[:error_message] = error_message if error_message
      attrs[:audit_log]     = audit_log + [ audit_entry ] if audit_entry

      update!(attrs)
      true
    end

    def append_audit!(entry)
      update!(audit_log: audit_log + [ entry.merge("at" => Time.current.iso8601) ])
    end

    def append_conflict!(conflict)
      update!(conflict_log: conflict_log + [ conflict.merge("at" => Time.current.iso8601) ])
    end

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    def step_count
      plan_steps.count
    end

    def total_steps
      plan_summary["total_steps"].to_i
    end
  end
end
