# frozen_string_literal: true

module System
  # System::ServiceGroup — a Unix group whose numeric GID is allocated
  # by the platform in the fleet-global 70000..99999 range and rendered
  # into /etc/group on every node that has at least one installed module
  # declaring it. Authority shifts from per-node useradd heuristics to a
  # central allocator so files on shared NFS or cross-node migrations
  # don't experience UID/GID drift.
  #
  # Allocation flows through System::Identity::GroupAllocator. Direct
  # .create! is permitted in specs but loses the collision guarantees
  # the allocator provides.
  #
  # Lifecycle mirrors Sdwan::HostVrfAssignment exactly:
  #   pending  → row created; agent has not yet rendered /etc/group
  #   active   → agent rendered + at least one module still declares it
  #   draining → last declaring module was uninstalled; row preserved
  #              for the 24h grace window so any NFS-resident files
  #              still group-owned by this GID aren't orphaned mid-flight
  #   removed  → reaper transitioned past 24h; GID is now free for reuse
  class ServiceGroup < ApplicationRecord
    include AASM

    self.table_name = "system_service_groups"

    STATES         = %w[pending active draining removed].freeze
    GID_MIN        = 70_000
    GID_MAX        = 99_999
    # POSIX portable name is [a-z_][a-z0-9_-]{0,30}$ (max 32 chars total).
    GROUPNAME_RX   = /\A[a-z_][a-z0-9_-]{0,30}\z/

    has_many :user_group_memberships,
             class_name: "System::ServiceUserGroupMembership",
             foreign_key: :service_group_id,
             dependent: :destroy
    has_many :members, through: :user_group_memberships, source: :service_user

    has_many :primary_users,
             class_name: "System::ServiceUser",
             foreign_key: :primary_group_id,
             dependent: :restrict_with_exception

    has_many :module_user_declarations,
             class_name: "System::ModuleUserDeclaration",
             foreign_key: :service_group_id,
             dependent: :destroy

    validates :groupname, presence: true,
                          format: { with: GROUPNAME_RX },
                          uniqueness: {
                            conditions: -> { where(state: %w[pending active draining]) }
                          }
    validates :gid, presence: true, uniqueness: true,
                    numericality: {
                      only_integer: true,
                      greater_than_or_equal_to: GID_MIN,
                      less_than_or_equal_to:    GID_MAX
                    }
    validates :state, inclusion: { in: STATES }

    scope :live,     -> { where(state: %w[pending active draining]) }
    scope :active,   -> { where(state: "active") }
    scope :draining, -> { where(state: "draining") }
    scope :removed,  -> { where(state: "removed") }

    aasm column: :state, whiny_transitions: false do
      state :pending
      state :active, initial: true
      state :draining
      state :removed

      event :mark_active do
        transitions from: %i[pending active draining], to: :active
        before { self.applied_at ||= Time.current }
      end

      event :start_drain do
        transitions from: %i[pending active draining], to: :draining
        before { self.draining_at ||= Time.current }
      end

      event :mark_removed do
        transitions from: %i[pending active draining removed], to: :removed
        before { self.removed_at ||= Time.current }
      end

      # Recover a row that operator/manifest re-declares before the
      # reaper has hard-transitioned it out of draining.
      event :readopt do
        transitions from: %i[draining removed], to: :active
        before do
          self.draining_at = nil
          self.removed_at  = nil
          self.applied_at ||= Time.current
        end
      end
    end
  end
end
