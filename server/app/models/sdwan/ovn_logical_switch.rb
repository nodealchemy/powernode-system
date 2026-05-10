# frozen_string_literal: true

# Sdwan::OvnLogicalSwitch — a logical L2 broadcast domain inside an OVN
# deployment. Operators create one per virtual network they want; the
# compiler emits an `ls-add <name>` entry per active row.
#
# Naming: OVN's `Logical_Switch.name` is bounded at 63 chars (matches
# `ovn-nbctl`'s own validation). The model also forbids whitespace
# inside the name — `ovn-nbctl` accepts it but the resulting
# command-line is awkward to consume programmatically.
#
# Lifecycle (AASM column: state):
#   pending  → row created; not yet emitted to OVN
#   active   → compiler is emitting it; northd has compiled it into SB
#   removed  → operator/AI tore it down; row stays for audit but is
#              excluded from compiler emissions (mirrors HostBridge)
#
# Phase O3 of the OVS+OVN dual-profile roadmap (heavyweight track).
module Sdwan
  class OvnLogicalSwitch < ApplicationRecord
    include AASM

    self.table_name = "sdwan_ovn_logical_switches"

    STATES = %w[pending active removed].freeze

    # OVN's Logical_Switch.name limit. Both the model and the DB
    # column enforce this so a bad name never reaches northd.
    NAME_MAX = 63
    NAME_FORMAT = /\A[\w\-.]+\z/.freeze

    belongs_to :account
    belongs_to :deployment,
               class_name: "Sdwan::OvnDeployment",
               foreign_key: :sdwan_ovn_deployment_id,
               inverse_of: :logical_switches

    has_many :ports,
             class_name: "Sdwan::OvnLogicalSwitchPort",
             foreign_key: :sdwan_ovn_logical_switch_id,
             dependent: :destroy,
             inverse_of: :logical_switch

    validates :name, presence: true,
                     length: { maximum: NAME_MAX },
                     format: { with: NAME_FORMAT,
                               message: "may only contain letters, digits, _, -, ." },
                     uniqueness: { scope: :sdwan_ovn_deployment_id }
    validates :state, inclusion: { in: STATES }
    # CIDR is optional — set when operators want OVN to serve DHCP
    # for the switch. We only validate that the value is non-blank if
    # present; full CIDR parsing happens in the compiler so a bad
    # value surfaces at compile time with a clear error.
    validates :cidr, length: { maximum: 64 }, allow_nil: true

    scope :active,      -> { where(state: "active") }
    scope :pending,     -> { where(state: "pending") }
    scope :removed,     -> { where(state: "removed") }
    # Compiler hook — only active rows are emitted. Pending rows are
    # waiting for explicit activation; removed rows are kept for audit
    # but excluded from the plan.
    scope :compilable,  -> { where(state: "active") }
    scope :for_deployment, ->(d) { where(sdwan_ovn_deployment_id: d.id) }

    aasm column: :state, whiny_transitions: false do
      state :pending, initial: true
      state :active
      state :removed

      event :mark_active do
        transitions from: %i[pending active], to: :active
        before { self.activated_at ||= Time.current }
      end

      event :mark_removed do
        transitions from: %i[pending active removed], to: :removed
        before { self.removed_at ||= Time.current }
      end

      event :readopt do
        # Recover a switch the operator marked removed but that the
        # compiler observers report as still wired in OVN.
        transitions from: :removed, to: :active
        before do
          self.removed_at = nil
          self.activated_at ||= Time.current
        end
      end
    end
  end
end
