# frozen_string_literal: true

module System
  # The platform's record that it unassigned a module from a node (IMP-9f4e162d9ed1).
  # Served to the node's agent as data.confirmed_unassigned so it can detach that
  # module even when its assignment list names no data-bearing module, the case it
  # otherwise refuses to act on (IMP-1023e79cc82d).
  #
  # Written ONLY by System::AssignmentClearanceService. There is deliberately no
  # controller, no MCP verb and no node-config route to it: a confirmation that
  # can be written without the service's audit row is not a confirmation.
  class NodeAssignmentClearance < BaseRecord
    REASONS = %w[assignment_destroyed assignment_disabled module_disabled module_destroyed].freeze

    belongs_to :account
    belongs_to :node, class_name: "System::Node"

    validates :node_module_id, :issued_at, :expires_at, presence: true
    validates :reason, inclusion: { in: REASONS }
    validates :node_module_id, uniqueness: { scope: :node_id }
    validate :window_is_forward

    scope :live, ->(now = Time.current) { where("expires_at > ?", now) }

    private

    def window_is_forward
      return if issued_at.blank? || expires_at.blank? || expires_at > issued_at

      errors.add(:expires_at, "must be after issued_at")
    end
  end
end
