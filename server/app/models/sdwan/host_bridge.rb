# frozen_string_literal: true

# Sdwan::HostBridge — represents a desired Linux (or, in Phase O2, OVS)
# bridge on a specific host (NodeInstance). The platform owns the
# bridge's name, addressing, and lifecycle end-to-end; the on-node
# agent's BridgeApplier reconciles host kernel state to match this row.
#
# Allocation flows through Sdwan::HostBridgeAllocator: that service owns
# the atomic short_id assignment under a per-host row lock and is the
# only supported way to mint new rows. Direct .create! is used by tests
# but loses the collision guarantees the allocator provides.
#
# Bridge name format: `pwnbr-<short_id>`. The 9999 ceiling keeps the
# widest derived name (`pwnbr-9999` = 10 chars) inside IFNAMSIZ
# (15 chars) with practical headroom.
#
# Lifecycle (AASM column: state, default: pending):
#   pending  → row created; agent has not yet applied the bridge
#   active   → agent confirmed the bridge exists and is UP
#   draining → operator/AI requested removal; the row is preserved so
#              in-flight taps using this bridge can finish their grace
#              window before the same short_id is reused
#   removed  → agent confirmed teardown; row stays for audit but is
#              excluded from compiler emissions
#
# Phase O1 of the OVS+OVN dual-profile roadmap (lightweight track).
module Sdwan
  class HostBridge < ApplicationRecord
    include AASM

    self.table_name = "sdwan_host_bridges"

    STATES = %w[pending active draining removed].freeze
    KINDS  = %w[linux ovs].freeze

    # IFNAMSIZ on Linux is 16 bytes including the trailing NUL, so the
    # kernel-visible iface name is capped at 15 chars. `pwnbr-9999` is
    # 10 chars — well under the limit even with future suffixing.
    BRIDGE_NAME_MAX = 15
    BRIDGE_NAME_PREFIX = "pwnbr"

    # Per-host counter for kernel iface names. 9999 ceiling keeps the
    # widest derived name inside IFNAMSIZ while leaving practical
    # headroom (no real fleet creates ≥10k bridges per host).
    SHORT_ID_MIN = 1
    SHORT_ID_MAX = 9999

    belongs_to :node_instance, class_name: "System::NodeInstance"
    belongs_to :account

    validates :short_id, presence: true,
                         numericality: {
                           only_integer: true,
                           greater_than_or_equal_to: SHORT_ID_MIN,
                           less_than_or_equal_to: SHORT_ID_MAX
                         },
                         uniqueness: { scope: :node_instance_id }
    validates :bridge_name, presence: true,
                            length: { maximum: BRIDGE_NAME_MAX },
                            uniqueness: { scope: :node_instance_id }
    validates :kind, inclusion: { in: KINDS }
    validates :state, inclusion: { in: STATES }

    scope :active,    -> { where(state: "active") }
    scope :draining,  -> { where(state: "draining") }
    scope :pending,   -> { where(state: "pending") }
    scope :removed,   -> { where(state: "removed") }
    # Compiler hook — rows the BridgeApplier compiler should emit for.
    # Includes draining so in-flight taps keep working until the agent
    # reports the bridge gone.
    scope :compilable, -> { where(state: %w[active draining]) }
    scope :for_host,   ->(host) { where(node_instance_id: host.id) }

    # Bridge name derivation — single source of truth shared between
    # the platform's TopologyCompiler and the agent's BridgeApplier.
    # Persisted on the row at allocation time so the agent reads the
    # desired name without re-deriving from short_id.
    def self.derive_bridge_name(short_id)
      "#{BRIDGE_NAME_PREFIX}-#{short_id}"
    end

    aasm column: :state, whiny_transitions: false do
      state :pending, initial: true
      state :active
      state :draining
      state :removed

      event :mark_active do
        transitions from: %i[pending active], to: :active
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
        # Recover a row that the agent reports as live but is locally
        # marked removed (drift remediation path).
        transitions from: :removed, to: :active
        before { self.removed_at = nil; self.applied_at ||= Time.current }
      end
    end
  end
end
