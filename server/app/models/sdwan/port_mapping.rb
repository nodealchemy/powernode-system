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
#
# Campaign 019f3458 increment 6 (hardened DNAT tier): rate_limit,
# max_connections, and source_cidrs are optional enforcement axes
# compiled by Sdwan::NatCompiler into the nft DNAT chain. All three are
# nil/empty by default — absence means unrestricted; there is no
# hardcoded platform-wide cap. See
# docs/runbooks/traefik-tcp-exposure-vs-dnat.md Path C.
module Sdwan
  class PortMapping < ApplicationRecord
    self.table_name = "system_sdwan_port_mappings"

    include Sdwan::LineSafeName

    PROTOCOLS = %w[tcp udp].freeze

    # ─── The one caller-writable attribute set (IMP-2c531ddb5a0c) ────────
    #
    # Read by EVERY surface that accepts a caller's attributes for this
    # resource: Api::V1::System::Sdwan::PortMappingsController#mapping_params
    # (REST create AND update, which share it) and Ai::Tools::SdwanTool's
    # create_port_mapping / update_port_mapping arms. Each used to carry its
    # own literal, and the two had drifted in BOTH directions on the same
    # action categories, the same executors and the same params shape: REST
    # alone could reassign the hub peer, MCP alone could set the hardened DNAT
    # tier (rate_limit / max_connections / source_cidrs) — so an operator
    # could not set a mapping's hardening at all while an agent could, and the
    # gating comments on both surfaces asserted they enforced one policy.
    #
    # Declared here rather than on either executor for the same reason
    # System::Executors::Base.replay_baseline_attributes is declared on the
    # executor: whatever several readers must agree on belongs in one place.
    # CreatePortMapping and UpdatePortMapping write the SAME columns and
    # neither owns the other's list, so the model — which owns these columns
    # and the validations that make each one safe to permit — is the seam.
    #
    # Adding a column here makes it writable from both surfaces at once. The
    # column-classification pin in spec/models/sdwan/port_mapping_spec.rb
    # reds on any new column that is neither listed here nor recorded as
    # deliberately non-writable, so a migration cannot land a field that is
    # silently outside every surface's reach.
    WRITABLE_SCALAR_ATTRIBUTES = %i[
      name description sdwan_peer_id target_peer_id target_virtual_ip_id
      listen_port target_port protocol enabled rate_limit max_connections
    ].freeze

    # Split out because strong parameters needs each non-scalar's SHAPE:
    # metadata is a free-form object, source_cidrs an array of scalars. A bare
    # `permit(:source_cidrs)` silently drops the array it was meant to accept.
    WRITABLE_STRUCTURED_ATTRIBUTES = { metadata: {}, source_cidrs: [] }.freeze

    WRITABLE_ATTRIBUTES = (WRITABLE_SCALAR_ATTRIBUTES + WRITABLE_STRUCTURED_ATTRIBUTES.keys).freeze

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
    validates :rate_limit, numericality: {
      only_integer: true, greater_than: 0
    }, allow_nil: true
    validates :max_connections, numericality: {
      only_integer: true, greater_than: 0
    }, allow_nil: true
    validate  :exactly_one_target
    validate  :hub_belongs_to_network
    validate  :target_within_network
    validate  :source_cidrs_must_be_valid

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

    # Splits source_cidrs into { v4: [...], v6: [...] } for
    # Sdwan::NatCompiler, which needs separate nft match clauses per
    # address family — a single `saddr` clause cannot mix `ip` and
    # `ip6` literals. Invalid entries are excluded defensively (model
    # validation should already have rejected them at save time, but a
    # compile must never raise on stale/legacy data).
    def source_cidrs_by_family
      entries = Array(source_cidrs).select { |cidr| valid_cidr?(cidr) }
      v4, v6 = entries.partition { |cidr| !cidr.include?(":") }
      { v4: v4, v6: v6 }
    end

    private

    def exactly_one_target
      target_count = [ target_peer_id, target_virtual_ip_id ].count(&:present?)
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

    # Same jsonb-array-of-CIDR-strings shape and IPAddr-based validity
    # check as System::FederationGrant#source_cidrs
    # (server/app/models/system/federation_grant.rb) — mirrored here
    # for consistency across the two "restrict by source IP" columns.
    # Unlike that sibling's batched (first 3) message, each invalid
    # entry gets its own error so an operator/AI caller sees exactly
    # which CIDR(s) failed.
    def source_cidrs_must_be_valid
      unless source_cidrs.is_a?(Array)
        errors.add(:source_cidrs, "must be an array (got #{source_cidrs.class.name})")
        return
      end

      source_cidrs.each do |entry|
        next if valid_cidr?(entry)

        errors.add(:source_cidrs, "contains an invalid CIDR entry: #{entry.inspect}")
      end
    end

    def valid_cidr?(cidr)
      return false unless cidr.is_a?(String) && cidr.present?

      IPAddr.new(cidr)
      true
    rescue IPAddr::InvalidAddressError, ArgumentError
      false
    end
  end
end
