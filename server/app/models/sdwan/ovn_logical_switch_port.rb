# frozen_string_literal: true

# Sdwan::OvnLogicalSwitchPort — a port on a logical switch. Maps 1:1 to
# OVN's `Logical_Switch_Port` row in the Northbound DB. Each port has a
# kind that drives compiler choices:
#
#   `vm`        — backed by a VM tap on a specific host
#   `container` — backed by a container veth on a specific host
#   `external`  — uplink/transit port; not host-backed
#
# MAC handling: the model auto-generates a locally-administered MAC
# (`02:` prefix + random) when one isn't supplied. The `02:` prefix
# selects the IEEE locally-administered range (bit 1 of the first
# octet set), which is reserved for site-administered values and
# cannot collide with vendor-assigned hardware OUIs. This is the same
# range OVN itself uses for synthetic ports when the operator does
# not pin a MAC, so the convention matches upstream behavior.
#
# Lifecycle (AASM column: state):
#   pending  → row created; not yet emitted to OVN
#   active   → compiler is emitting it; the port exists in OVN
#   removed  → operator/AI deleted it; row stays for audit but is
#              excluded from compiler emissions
#
# Phase O3 of the OVS+OVN dual-profile roadmap (heavyweight track).
module Sdwan
  class OvnLogicalSwitchPort < ApplicationRecord
    include AASM

    self.table_name = "sdwan_ovn_logical_switch_ports"

    STATES = %w[pending active removed].freeze
    KINDS  = %w[vm container external].freeze

    # OVN's port name limit. The DB column is also bounded at 63 so
    # bad data can't reach northd through bypassed validators.
    NAME_MAX = 63
    NAME_FORMAT = /\A[\w\-.]+\z/.freeze

    # MAC validator — OVN's parser accepts case-insensitive hex with
    # `:` separators. We normalize to lower-case at generation time
    # but accept either form on the way in.
    MAC_FORMAT = /\A[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}\z/.freeze

    belongs_to :account
    belongs_to :logical_switch,
               class_name: "Sdwan::OvnLogicalSwitch",
               foreign_key: :sdwan_ovn_logical_switch_id,
               inverse_of: :ports
    # Nullable — only set for vm/container ports. External ports
    # (router uplinks, transit ports) leave this NULL because no
    # specific host backs them.
    belongs_to :host_node_instance,
               class_name: "System::NodeInstance",
               optional: true

    validates :name, presence: true,
                     length: { maximum: NAME_MAX },
                     format: { with: NAME_FORMAT,
                               message: "may only contain letters, digits, _, -, ." },
                     uniqueness: { scope: :sdwan_ovn_logical_switch_id }
    validates :mac, presence: true, format: { with: MAC_FORMAT }
    validates :kind, inclusion: { in: KINDS }
    validates :state, inclusion: { in: STATES }
    validate :addresses_must_be_array_of_strings

    before_validation :assign_mac_if_blank
    before_validation :coerce_addresses_default

    scope :active,        -> { where(state: "active") }
    scope :pending,       -> { where(state: "pending") }
    scope :removed,       -> { where(state: "removed") }
    # Compiler hook — only active rows are emitted.
    scope :compilable,    -> { where(state: "active") }
    scope :for_switch,    ->(s) { where(sdwan_ovn_logical_switch_id: s.id) }
    scope :for_host,      ->(h) { where(host_node_instance_id: h.id) }
    scope :external,      -> { where(kind: "external") }

    # Generates a locally-administered MAC (`02:xx:xx:xx:xx:xx`).
    # The `02` first byte sets the U/L bit (bit 1) — IEEE-reserved
    # for locally-administered values, so the result is guaranteed
    # never to collide with a vendor OUI.
    def self.generate_mac
      bytes = Array.new(5) { rand(0..255) }
      ([0x02] + bytes).map { |b| b.to_s(16).rjust(2, "0") }.join(":")
    end

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
        transitions from: :removed, to: :active
        before do
          self.removed_at = nil
          self.activated_at ||= Time.current
        end
      end
    end

    private

    def assign_mac_if_blank
      self.mac = self.class.generate_mac if mac.blank?
    end

    # JSONB columns reject Ruby nils where Postgres expects an array.
    # Default the column to [] when callers leave it unset.
    def coerce_addresses_default
      self.addresses = [] if addresses.nil?
    end

    # The compiler joins the addresses into OVN's space-separated
    # `addresses=` syntax — non-string values would render junk
    # commands, so we reject them at the model boundary.
    def addresses_must_be_array_of_strings
      return if addresses.is_a?(Array) && addresses.all? { |a| a.is_a?(String) }

      errors.add(:addresses, "must be an array of strings")
    end
  end
end
