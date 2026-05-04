# frozen_string_literal: true

# Account-scoped SDWAN overlay network. The cidr_64 is allocated by
# Sdwan::PrefixAllocator the first time a network is saved; it carves a
# deterministic /64 from the account's /48 and verifies non-collision
# within the account.
#
# Network status:
#   registered — created, no peers yet, compiler emits nothing
#   active     — at least one peer is healthy, compiler emits per-peer config
#   suspended  — operator-paused, compiler returns deny-all
#   archived   — read-only, audit retention
#
# Slice 1 of the SDWAN plan.
module Sdwan
  class Network < ApplicationRecord
    self.table_name = "sdwan_networks"

    STATUSES = %w[registered active suspended archived].freeze
    # Slice 9a — per-network routing layer.
    # static: declarative AllowedIPs, no daemon (slice 9a fold-in)
    # ibgp:   FRR + dynamic distribution via route reflectors (slice 9c)
    ROUTING_PROTOCOLS = %w[static ibgp].freeze

    belongs_to :account
    has_many :peers, class_name: "Sdwan::Peer", foreign_key: :sdwan_network_id, dependent: :destroy
    has_many :firewall_rules, class_name: "Sdwan::FirewallRule",
             foreign_key: :sdwan_network_id, dependent: :destroy
    has_many :access_grants,  class_name: "Sdwan::AccessGrant",
             foreign_key: :sdwan_network_id, dependent: :destroy
    has_many :user_devices, through: :access_grants, source: :user_devices
    # Slice 9b — first-class VIPs hosted by one or more peers in this network.
    has_many :virtual_ips, class_name: "Sdwan::VirtualIp",
             foreign_key: :sdwan_network_id, dependent: :destroy
    # Slice 7b — hub DNAT mappings.
    has_many :port_mappings, class_name: "Sdwan::PortMapping",
             foreign_key: :sdwan_network_id, dependent: :destroy
    has_many :subnet_advertisements, class_name: "Sdwan::SubnetAdvertisement",
             foreign_key: :sdwan_network_id, dependent: :destroy

    validates :name, presence: true, length: { maximum: 64 },
                     uniqueness: { scope: :account_id }
    validates :slug, presence: true, length: { maximum: 64 },
                     format: { with: /\A[a-z0-9][a-z0-9\-]*\z/ },
                     uniqueness: { scope: :account_id }
    validates :status, inclusion: { in: STATUSES }
    validates :routing_protocol, inclusion: { in: ROUTING_PROTOCOLS }
    validates :cidr_64, presence: true, format: {
      with: /\Afd[0-9a-f:]+::\/64\z/i,
      message: "must be a /64 ULA prefix"
    }, uniqueness: true
    validates :route_reflector_redundancy, numericality: {
      only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 16
    }

    before_validation :generate_slug, if: -> { name.present? && slug.blank? }
    before_validation :allocate_address_space, on: :create

    scope :active,     -> { where(status: "active") }
    scope :compilable, -> { where(status: %w[registered active]) }
    scope :static_routing, -> { where(routing_protocol: "static") }
    scope :ibgp_routing,   -> { where(routing_protocol: "ibgp") }

    def static_routing?
      routing_protocol == "static"
    end

    def ibgp_routing?
      routing_protocol == "ibgp"
    end

    def compilable?
      %w[registered active].include?(status)
    end

    # The /64 minus the trailing "/64" suffix — useful when the compiler
    # needs to emit a peer's /128 with full host bits.
    def network_prefix_only
      cidr_64.to_s.sub(%r{/64\z}, "")
    end

    private

    def generate_slug
      base = name.downcase.gsub(/[^a-z0-9\s-]/, "").gsub(/\s+/, "-").squeeze("-")
      base = base.sub(/\A-+/, "").sub(/-+\z/, "")
      base = "network" if base.blank?

      candidate = base
      counter = 1
      while account_id && self.class.where(account_id: account_id, slug: candidate).where.not(id: id).exists?
        candidate = "#{base}-#{counter}"
        counter += 1
      end

      self.slug = candidate
    end

    def allocate_address_space
      return if cidr_64.present?
      return if account_id.blank?

      self.cidr_64 = Sdwan::PrefixAllocator.allocate_network_cidr!(account_id: account_id, network_id: id || UUID7.generate)
    end
  end
end
