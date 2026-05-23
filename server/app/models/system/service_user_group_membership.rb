# frozen_string_literal: true

module System
  # System::ServiceUserGroupMembership — many-to-many join between a
  # ServiceUser and the supplementary ServiceGroups they belong to. The
  # ServiceUser's *primary* group is its own column on the user row
  # (primary_group_id); this table stores ONLY supplementary memberships
  # so the agent can render correct `group:gid:name,...` lines in
  # /etc/group.
  class ServiceUserGroupMembership < ApplicationRecord
    self.table_name = "system_service_user_group_memberships"

    belongs_to :service_user,  class_name: "System::ServiceUser"
    belongs_to :service_group, class_name: "System::ServiceGroup"

    validates :service_user_id,
              uniqueness: { scope: :service_group_id }
  end
end
