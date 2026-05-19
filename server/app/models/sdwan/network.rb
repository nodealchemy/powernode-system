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
    # Phase N1a — host-scoped VRF assignments. One row per (network, host)
    # carries the per-host kernel routing-table id used to isolate this
    # network's iBGP RIB and forwarding context from any other network
    # the same host belongs to.
    has_many :host_vrf_assignments, class_name: "Sdwan::HostVrfAssignment",
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
    validate :pod_subnet_prefix_format
    validate :pod_subnet_prefix_no_overlap
    validate :pod_subnet_prefix_immutable_when_clusters_active

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

    # Phase N1a — short, deterministic per-network handle. Used both as
    # the WG iface short id (`wg-sdwan-<handle>`) and as the VRF master
    # device name (`sdwan-<handle>`). 6 hex chars sourced from the UUID
    # primary key — the budget is set by Linux's IFNAMSIZ (15 usable),
    # and `wg-sdwan-` (9) + 6 = 15 is the tightest binding constraint.
    # 24 bits of entropy gives ~16M unique handles per account.
    def network_handle
      id.to_s.delete("-").first(6)
    end

    # Phase N1a — render the VRF iface name for a host using
    # vrf_name_template. Substitutes {handle} with the network handle.
    # Hosts within an account share the template, so the same network
    # has a single canonical VRF iface name; the per-host scope of
    # Sdwan::HostVrfAssignment exists only because table_id allocation
    # is per-host.
    def vrf_name_for(_host = nil)
      template = vrf_name_template.presence || "sdwan-{handle}"
      template.gsub("{handle}", network_handle)
    end

    # True when this network has a pod CIDR carried over the overlay.
    # K3s clusters bootstrapped on this network use flannel host-gw + the
    # AllowedIPs covering the /64 to encrypt pod-to-pod traffic via the
    # existing WireGuard tunnels.
    def pod_overlay_enabled?
      pod_subnet_prefix.present?
    end

    private

    def pod_subnet_prefix_format
      return if pod_subnet_prefix.blank?

      addr = IPAddr.new(pod_subnet_prefix)
      if addr.ipv4? && addr.prefix > 28
        errors.add(:pod_subnet_prefix, "IPv4 pod CIDR must be /28 or larger (pods need address space)")
      end
    rescue IPAddr::Error
      errors.add(:pod_subnet_prefix, "must be a CIDR (e.g. 10.42.0.0/16 or fd00:abcd:2::/64)")
    end

    def pod_subnet_prefix_no_overlap
      return if pod_subnet_prefix.blank?

      pod_addr = IPAddr.new(pod_subnet_prefix)

      # (a) Must not overlap the SDWAN /64 itself.
      if cidr_64.present?
        begin
          sdwan_addr = IPAddr.new(cidr_64.to_s.sub(%r{/64\z}, "/64"))
          if pod_addr.include?(sdwan_addr) || sdwan_addr.include?(pod_addr)
            errors.add(:pod_subnet_prefix, "must not overlap the SDWAN /64 (#{cidr_64})")
          end
        rescue IPAddr::Error
          # cidr_64 invalid — handled by its own validation
        end
      end

      # (b) Must not overlap any peer's lan_subnets in this network.
      peers.find_each do |peer|
        Array(peer.lan_subnets).each do |sub|
          begin
            sub_addr = IPAddr.new(sub.to_s)
            if pod_addr.include?(sub_addr) || sub_addr.include?(pod_addr)
              errors.add(:pod_subnet_prefix, "must not overlap peer LAN subnet #{sub}")
            end
          rescue IPAddr::Error
            next
          end
        end
      end

      # (c) Must not overlap any VIP /128 in this network.
      virtual_ips.find_each do |vip|
        next if vip.assigned_address.blank?

        begin
          vip_addr = IPAddr.new("#{vip.assigned_address}/128")
          if pod_addr.include?(vip_addr) || vip_addr.include?(pod_addr)
            errors.add(:pod_subnet_prefix, "must not overlap VIP #{vip.assigned_address}")
          end
        rescue IPAddr::Error
          next
        end
      end

      # (d) Must not overlap any other network's pod_subnet_prefix in the same account.
      return if account_id.blank?

      self.class.where(account_id: account_id)
                .where.not(id: id)
                .where.not(pod_subnet_prefix: [nil, ""])
                .find_each do |other|
        begin
          other_addr = IPAddr.new(other.pod_subnet_prefix)
          if pod_addr.include?(other_addr) || other_addr.include?(pod_addr)
            errors.add(:pod_subnet_prefix, "must not overlap network '#{other.name}' pod_subnet_prefix #{other.pod_subnet_prefix}")
          end
        rescue IPAddr::Error
          next
        end
      end
    end

    # Refuses pod_subnet_prefix changes once a Devops::KubernetesCluster
    # references this network (via cluster.metadata["sdwan_network_id"]).
    # K3s pod CIDR is immutable post-bootstrap, so mutating the field
    # would create a routing/cluster mismatch with no recovery path
    # short of cluster destroy + rebuild.
    def pod_subnet_prefix_immutable_when_clusters_active
      return unless pod_subnet_prefix_changed?
      return if new_record?

      return unless defined?(::Devops::KubernetesCluster)

      cluster_count = ::Devops::KubernetesCluster
                        .where("metadata->>'sdwan_network_id' = ?", id.to_s)
                        .count
      if cluster_count.positive?
        errors.add(:pod_subnet_prefix,
                   "cannot change while #{cluster_count} K3s cluster(s) reference this network — destroy + rebuild required")
      end
    end

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
