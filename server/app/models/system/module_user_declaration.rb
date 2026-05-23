# frozen_string_literal: true

module System
  # System::ModuleUserDeclaration — records the fact that a particular
  # NodeModule's manifest declares a particular ServiceUser or
  # ServiceGroup. Powers two queries:
  #
  #   1. Reaper: "no module still declares this identity → safe to
  #      transition from draining to removed after the 24h grace."
  #   2. Agent: "which identities should I render on a node that has
  #      this module installed?" — though the agent typically gets the
  #      pre-joined list via the modules controller's serializer.
  #
  # Exactly one of service_user / service_group is non-null per row
  # (enforced by a check constraint in the migration). This keeps the
  # query "modules that own X" simple — there's a single join column.
  class ModuleUserDeclaration < ApplicationRecord
    self.table_name = "system_module_user_declarations"

    belongs_to :node_module,   class_name: "System::NodeModule"
    belongs_to :service_user,  class_name: "System::ServiceUser",  optional: true
    belongs_to :service_group, class_name: "System::ServiceGroup", optional: true

    validate :exactly_one_target
    before_destroy :drain_orphaned_identity!

    scope :for_user,  ->(user_id)  { where(service_user_id: user_id) }
    scope :for_group, ->(group_id) { where(service_group_id: group_id) }

    private

    def exactly_one_target
      user_set  = service_user_id.present?
      group_set = service_group_id.present?
      return if user_set ^ group_set

      errors.add(:base, "exactly one of service_user or service_group must be set")
    end

    # When the last declaration referencing a user/group is destroyed,
    # start the 24h drain on the identity itself. Reaper later flips
    # draining → removed and frees the UID/GID for reuse.
    def drain_orphaned_identity!
      identity = service_user || service_group
      return unless identity
      remaining = self.class
                      .where.not(id: id)
                      .where(
                        service_user_id:  service_user_id,
                        service_group_id: service_group_id
                      ).count
      return if remaining.positive?
      identity.start_drain! if identity.may_start_drain?
    end
  end
end
