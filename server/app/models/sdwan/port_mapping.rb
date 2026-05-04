# frozen_string_literal: true

# Sdwan::PortMapping — declarative DNAT on a hub peer's underlay
# interface. The compiler emits nft rules of the shape:
#
#   <protocol> dport <listen_port> dnat to [<target_overlay_addr>]:<target_port>
#
# Hub peers publish overlay services to v4-only clients via this
# mapping. Routing back to the target uses the existing slice 1 WG
# AllowedIPs (the target's /128 is already covered by the hub's
# [Peer] section pointing at it).
#
# v4-only clients hit the hub's *underlay* address on listen_port; the
# DNAT translates the destination to the target's overlay /128, which
# the kernel routes through the WG interface — completing the v4-only
# → overlay service bridge without any 6in4 tunneling on the client.
#
# Slice 9b extension: target can be a VirtualIp instead of a specific
# peer. The compiler resolves to the VIP's primary holder at compile
# time, so a single DNAT rule follows the VIP across failovers.
#
# Slice 7b of the SDWAN plan.
module Sdwan
  class PortMapping < ApplicationRecord
    self.table_name = "sdwan_port_mappings"

    PROTOCOLS = %w[tcp udp].freeze

    belongs_to :account
    belongs_to :network, class_name: "Sdwan::Network", foreign_key: :sdwan_network_id
    belongs_to :hub_peer, class_name: "Sdwan::Peer", foreign_key: :sdwan_peer_id
    belongs_to :target_peer, class_name: "Sdwan::Peer",
               foreign_key: :target_peer_id, optional: true
    belongs_to :target_virtual_ip, class_name: "Sdwan::VirtualIp",
               foreign_key: :target_virtual_ip_id, optional: true

    validates :name, presence: true, length: { maximum: 64 }
    validates :listen_port, presence: true, numericality: {
      only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535
    }
    validates :target_port, numericality: {
      only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535
    }, allow_nil: true
    validates :protocol, inclusion: { in: PROTOCOLS }
    validates :sdwan_peer_id, uniqueness: { scope: %i[listen_port protocol] }
    validate  :exactly_one_target
    validate  :hub_belongs_to_network
    validate  :target_within_network

    scope :enabled, -> { where(enabled: true) }
    scope :for_hub, ->(peer_id) { where(sdwan_peer_id: peer_id) }

    # The port the target peer/VIP receives on. Defaults to listen_port
    # if the operator didn't supply a different target_port — the common
    # case is "publish 5432 → reach 5432 on the database peer."
    def effective_target_port
      target_port.presence || listen_port
    end

    # Returns the overlay /128 (or /32) that DNAT should rewrite to.
    # When target is a VIP, returns the VIP's CIDR — the WG kernel
    # routes that prefix to whichever peer holds it (via AllowedIPs).
    # If the VIP has no holder yet (state=unassigned), returns nil so
    # the compiler skips the rule rather than installing a black-hole
    # DNAT that no peer will accept.
    def resolved_target_address
      if target_peer_id.present?
        addr = target_peer&.assigned_address.to_s.split("/").first
        addr.presence
      elsif target_virtual_ip_id.present?
        vip = target_virtual_ip
        return nil if vip.nil?
        return nil if Array(vip.holder_peer_ids).empty?

        vip.cidr.to_s.split("/").first
      end
    end

    private

    def exactly_one_target
      target_count = [target_peer_id, target_virtual_ip_id].count(&:present?)
      return if target_count == 1

      errors.add(:base, "exactly one of target_peer_id or target_virtual_ip_id must be set")
    end

    def hub_belongs_to_network
      return if hub_peer.nil? || sdwan_network_id.nil?
      return if hub_peer.sdwan_network_id == sdwan_network_id

      errors.add(:sdwan_peer_id, "hub peer must belong to the network")
    end

    def target_within_network
      if target_peer && target_peer.sdwan_network_id != sdwan_network_id
        errors.add(:target_peer_id, "target peer must belong to the same network")
      end
      if target_virtual_ip && target_virtual_ip.sdwan_network_id != sdwan_network_id
        errors.add(:target_virtual_ip_id, "target VIP must belong to the same network")
      end
    end
  end
end
