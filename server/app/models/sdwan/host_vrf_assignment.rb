# frozen_string_literal: true

# Sdwan::HostVrfAssignment — joins one host (NodeInstance) to one
# Sdwan::Network with the per-host kernel routing-table id and Linux
# VRF master device name that scope this network's BGP RIB and
# forwarding decisions on the host.
#
# Allocation flows through Sdwan::VrfAllocator: that service owns the
# atomic table_id assignment under a per-host row lock and is the only
# supported way to mint new rows. Direct .create! is used by tests but
# loses the collision guarantees the allocator provides.
#
# Lifecycle (AASM column: state, default: pending):
#   pending  → row created; the agent has not yet applied the VRF
#   active   → agent confirmed the VRF master device exists and the
#              network's WG iface is bound to it
#   draining → operator/AI requested removal; the row is preserved so
#              in-flight tunnels using this table-id can finish their
#              grace window before the same id is reused
#   removed  → agent confirmed teardown; row stays for audit but is
#              excluded from compiler emissions
#
# Phase N1a of the in-house encrypted mesh overlay roadmap.
module Sdwan
  class HostVrfAssignment < ApplicationRecord
    include AASM

    self.table_name = "system_sdwan_host_vrf_assignments"

    STATES = %w[pending active draining removed].freeze

    # Reserved kernel routing tables — VrfAllocator must never hand
    # these out and the model rejects them defensively in case of a
    # direct insert that bypasses the allocator.
    RESERVED_TABLE_IDS = [ 0, 253, 254, 255 ].freeze
    TABLE_ID_MIN = 100
    TABLE_ID_MAX = 65_535
    # IFNAMSIZ on Linux is 16 bytes including the trailing NUL, so the
    # kernel-visible iface name is capped at 15 chars.
    VRF_NAME_MAX = 15
    # Per-host counter for kernel iface names. 9999 ceiling keeps the
    # widest derived name (`wg-sdwan-9999` = 13 chars) inside IFNAMSIZ
    # while leaving practical headroom (no real fleet joins ≥10k
    # networks per host).
    SHORT_ID_MIN = 1
    SHORT_ID_MAX = 9999

    belongs_to :node_instance, class_name: "System::NodeInstance"
    belongs_to :network, class_name: "Sdwan::Network",
               foreign_key: :sdwan_network_id
    belongs_to :account

    validates :table_id, presence: true,
                         numericality: {
                           only_integer: true,
                           greater_than_or_equal_to: TABLE_ID_MIN,
                           less_than_or_equal_to: TABLE_ID_MAX
                         },
                         uniqueness: { scope: :node_instance_id }
    validates :vrf_name, presence: true,
                         length: { maximum: VRF_NAME_MAX },
                         uniqueness: { scope: :node_instance_id }
    validates :short_id, presence: true,
                         numericality: {
                           only_integer: true,
                           greater_than_or_equal_to: SHORT_ID_MIN,
                           less_than_or_equal_to: SHORT_ID_MAX
                         },
                         uniqueness: { scope: :node_instance_id }
    validates :state, inclusion: { in: STATES }
    validate :table_id_not_reserved

    # Kernel-visible iface names — single source of truth for both the
    # platform's TopologyCompiler and the agent's appliers. All three
    # fit IFNAMSIZ (15 chars max) for short_id values up to 9999.
    def vrf_iface_name
      "sdwan-#{short_id}"
    end

    def wg_iface_name
      "wg-sdwan-#{short_id}"
    end

    # THE SINGLE SOURCE for the WireGuard interface name on a given host+
    # network, for every server-side producer.
    #
    # IMP-54fdf40fbf9d: this name had five producers and they disagreed. The
    # agent creates whatever TopologyCompiler puts in the interface block
    # (wg_applier.go: `ip link add <cfg.Name> type wireguard`), which is the
    # HVA form above. The firewall compiler's `iif`, the k3s flannel_iface and
    # the storage mount hint each re-derived "wg-sdwan-<network_handle>"
    # independently, so all three named a device that never exists — and an
    # nftables rule whose iif matches nothing fails OPEN.
    #
    # The fallback is NOT a bug and is kept: static-only networks allocate no
    # HVA, and there is one network per host on that path, so the handle form
    # is collision-free there. What matters is that every producer resolves it
    # THE SAME WAY, which is why this lives on the model that owns the name
    # rather than being re-derived per call site.
    #
    # The live set is `compilable` (see the scope below) — active AND draining.
    # It is NOT respelled here: a second copy of that array is precisely the
    # drift this method exists to remove, one level down. Widening the scope
    # must widen the firewall's view with it.
    def self.wg_iface_name_for(network:, node_instance:)
      assignment =
        if node_instance
          compilable.where(node_instance_id: node_instance.id,
                           sdwan_network_id: network.id).first
        end

      wg_iface_name_from(assignment: assignment, network: network)
    end

    # The same resolution for a caller that has ALREADY loaded the assignment.
    # TopologyCompiler caches one HVA per (host, network) per compile and would
    # otherwise re-query per peer and per firewall rule; this keeps the
    # fallback string single-sourced without giving up that cache.
    def self.wg_iface_name_from(assignment:, network:)
      return assignment.wg_iface_name if assignment

      "wg-sdwan-#{network.network_handle}"
    end

    def dummy_iface_name
      "d-sdwan-#{short_id}"
    end

    scope :active,    -> { where(state: "active") }
    scope :draining,  -> { where(state: "draining") }
    scope :pending,   -> { where(state: "pending") }
    scope :removed,   -> { where(state: "removed") }
    # Compiler hook — rows the FRR config compiler should emit for. The
    # draining state is intentionally included: in-flight neighbors must
    # keep their adjacency until the agent reports the VRF removed.
    scope :compilable, -> { where(state: %w[active draining]) }
    scope :for_host,  ->(host) { where(node_instance_id: host.id) }

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

    private

    def table_id_not_reserved
      return if table_id.blank?
      return unless RESERVED_TABLE_IDS.include?(table_id)

      errors.add(:table_id,
                 "is reserved by the kernel (0=unspec, 253=default, " \
                 "254=main, 255=local)")
    end
  end
end
