# frozen_string_literal: true

# Sdwan::SubnetAdvertisement — observed/declared route advertisement.
#
# Four sources unified into one table:
#   declared_lan_subnet — operator declared via Sdwan::Peer.lan_subnets
#   virtual_ip          — slice 9b VIP machinery emits one row per active VIP
#   learned_via_bgp     — slice 9c FRR observer emits one row per learned route
#   pod_subnet          — K3s cluster pod CIDR (added 2026-05-19, k3s overlay
#                         feature); emitted by KubernetesClusterProvisionerService
#                         at bootstrap when the cluster runs flannel + the network
#                         has pod_subnet_prefix set
#
# The operator UI's `LearnedRoutesTable` filters by source; the topology
# diagram annotates edges with prefix counts derived from these rows.
#
# Slice 9a of the SDWAN plan; pod_subnet source added by the k3s-flannel-
# over-sdwan feature.
module Sdwan
  class SubnetAdvertisement < ApplicationRecord
    self.table_name = "sdwan_subnet_advertisements"

    SOURCES = %w[declared_lan_subnet virtual_ip learned_via_bgp pod_subnet].freeze

    belongs_to :peer,    class_name: "Sdwan::Peer",    foreign_key: :sdwan_peer_id
    belongs_to :network, class_name: "Sdwan::Network", foreign_key: :sdwan_network_id
    belongs_to :account
    belongs_to :origin_peer, class_name: "Sdwan::Peer", optional: true
    belongs_to :via_peer,    class_name: "Sdwan::Peer", optional: true

    validates :prefix, presence: true, format: {
      with: %r{\A[0-9a-f.:]+/\d{1,3}\z}i,
      message: "must be a CIDR (v4 or v6)"
    }
    validates :source, inclusion: { in: SOURCES }

    scope :active,     -> { where(withdrawn_at: nil) }
    scope :withdrawn,  -> { where.not(withdrawn_at: nil) }
    scope :declared,   -> { where(source: "declared_lan_subnet") }
    scope :vip,        -> { where(source: "virtual_ip") }
    scope :learned,    -> { where(source: "learned_via_bgp") }
    scope :pod_subnet, -> { where(source: "pod_subnet") }

    before_validation :inherit_account_from_network

    def withdraw!(at: Time.current)
      return if withdrawn_at.present?

      update!(withdrawn_at: at)
    end

    def active?
      withdrawn_at.nil?
    end

    private

    def inherit_account_from_network
      return if account_id.present?
      return if sdwan_network_id.blank?

      self.account_id = network&.account_id
    end
  end
end
