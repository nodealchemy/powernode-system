# frozen_string_literal: true

module System
  # System::ServiceUser — a Unix service account whose numeric UID is
  # allocated by the platform in the fleet-global 70000..99999 range and
  # rendered into /etc/passwd on every node that has at least one
  # installed module declaring it.
  #
  # Allocation flows through System::Identity::UserAllocator, which also
  # auto-creates the primary System::ServiceGroup (same name) if the
  # manifest doesn't declare it explicitly. Direct .create! is permitted
  # in specs but loses the collision guarantees the allocator provides.
  #
  # Password is always `*` (locked) in the rendered /etc/shadow — these
  # are service accounts, never interactive logins. To grant a service
  # account narrow root capabilities, declare a System::SudoersGrant
  # rather than unlocking the password.
  #
  # Lifecycle mirrors System::ServiceGroup (and Sdwan::HostVrfAssignment).
  class ServiceUser < ApplicationRecord
    include AASM

    self.table_name = "system_service_users"

    STATES      = %w[pending active draining removed].freeze
    UID_MIN     = 70_000
    UID_MAX     = 99_999
    USERNAME_RX = /\A[a-z_][a-z0-9_-]{0,30}\z/

    belongs_to :primary_group,
               class_name: "System::ServiceGroup",
               foreign_key: :primary_group_id

    has_many :user_group_memberships,
             class_name: "System::ServiceUserGroupMembership",
             foreign_key: :service_user_id,
             dependent: :destroy
    has_many :supplementary_groups,
             through: :user_group_memberships,
             source: :service_group

    has_many :module_user_declarations,
             class_name: "System::ModuleUserDeclaration",
             foreign_key: :service_user_id,
             dependent: :destroy

    has_many :sudoers_grants,
             class_name: "System::SudoersGrant",
             foreign_key: :service_user_id,
             dependent: :destroy

    has_many :module_services,
             class_name: "System::ModuleService",
             foreign_key: :service_user_id,
             dependent: :restrict_with_exception

    validates :username, presence: true,
                         format: { with: USERNAME_RX },
                         uniqueness: {
                           conditions: -> { where(state: %w[pending active draining]) }
                         }
    validates :uid, presence: true, uniqueness: true,
                    numericality: {
                      only_integer: true,
                      greater_than_or_equal_to: UID_MIN,
                      less_than_or_equal_to:    UID_MAX
                    }
    validates :shell, presence: true, length: { maximum: 128 }
    validates :home,  presence: true, length: { maximum: 256 }
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

      event :readopt do
        transitions from: %i[draining removed], to: :active
        before do
          self.draining_at = nil
          self.removed_at  = nil
          self.applied_at ||= Time.current
        end
      end
    end

    def primary_gid
      primary_group&.gid
    end

    def primary_groupname
      primary_group&.groupname
    end
  end
end
