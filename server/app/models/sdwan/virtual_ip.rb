# frozen_string_literal: true

# Sdwan::VirtualIp — first-class VIP object hosted by one (or more, in
# slice 9c anycast mode) peers in an SDWAN network.
#
# Static mode (slice 9b): single active holder; agent configures the
# address on its loopback; topology compiler emits AllowedIPs on every
# other peer pointing the VIP's CIDR at the holder's overlay /128.
#
# Anycast mode (slice 9c): all `holder_peer_ids` configure the address
# simultaneously; FRR's BGP daemon advertises the prefix from each;
# closest-path routing picks the actual destination.
#
# Slice 9b of the SDWAN plan.
module Sdwan
  class VirtualIp < ApplicationRecord
    self.table_name = "sdwan_virtual_ips"

    STATES = %w[pending active failing_over unassigned error].freeze

    belongs_to :network, class_name: "Sdwan::Network", foreign_key: :sdwan_network_id
    belongs_to :account
    has_many :assignments,
             class_name: "Sdwan::VirtualIpAssignment",
             foreign_key: :sdwan_virtual_ip_id,
             dependent: :destroy

    validates :name, presence: true, length: { maximum: 64 },
                     uniqueness: { scope: :sdwan_network_id }
    validates :cidr, presence: true, format: {
      with: %r{\A[0-9a-f.:]+/\d{1,3}\z}i,
      message: "must be a CIDR (v4 or v6)"
    }, uniqueness: { scope: :account_id }
    validates :state, inclusion: { in: STATES }
    validates :advertised_med, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :advertised_local_pref, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :holder_peers_belong_to_network
    validate :anycast_requires_holder_set

    before_validation :inherit_account_from_network

    scope :active,      -> { where(state: "active") }
    scope :unassigned,  -> { where(state: "unassigned") }
    scope :anycast_set, -> { where(anycast: true) }

    # ---- Holder accessors ----------------------------------------

    def holders
      return ::Sdwan::Peer.none if Array(holder_peer_ids).empty?

      ::Sdwan::Peer.where(id: Array(holder_peer_ids))
    end

    def primary_holder
      return nil if Array(holder_peer_ids).empty?

      ::Sdwan::Peer.find_by(id: Array(holder_peer_ids).first)
    end

    def fallback_candidates
      return ::Sdwan::Peer.none if Array(failover_holder_peer_ids).empty?

      ::Sdwan::Peer.where(id: Array(failover_holder_peer_ids))
    end

    def held_by?(peer)
      return false if Array(holder_peer_ids).empty?
      return false unless peer

      Array(holder_peer_ids).include?(peer.id)
    end

    # Used by the agent payload — peers receive the VIPs they currently
    # hold (loopback config) and the VIPs they need to route to (allowed-
    # IPs in other peers' WG configs).
    def cidr_with_host_only?
      mask = cidr.split("/", 2).last.to_i
      cidr.include?(":") ? mask == 128 : mask == 32
    end

    # ---- Mutating ops ----------------------------------------------

    # Slice 9b — manual failover for non-anycast VIPs. Pops the head of
    # `holder_peer_ids` (current primary), pushes it to the back of
    # `failover_holder_peer_ids`, and promotes the head of failover to
    # holder. Records the assignment transition.
    def failover!(reason: "manual_failover", triggered_by_user: nil, correlation_id: nil)
      raise StateError, "anycast VIPs don't fail over (all holders active simultaneously)" if anycast?
      raise StateError, "no failover candidates configured" if Array(failover_holder_peer_ids).empty?

      transaction do
        old_holder = Array(holder_peer_ids).first
        new_holder = Array(failover_holder_peer_ids).first

        new_holders  = ([new_holder] + (Array(holder_peer_ids) - [new_holder]))
        new_failover = (Array(failover_holder_peer_ids) - [new_holder]) + ([old_holder].compact)

        update!(
          holder_peer_ids: new_holders.compact,
          failover_holder_peer_ids: new_failover.compact,
          state: "active"
        )

        if old_holder
          assignments.where(sdwan_peer_id: old_holder, released_at: nil)
                     .update_all(released_at: Time.current, updated_at: Time.current)
        end

        if new_holder
          assignments.create!(
            peer: ::Sdwan::Peer.find(new_holder),
            assumed_at: Time.current,
            reason: reason.to_s,
            triggered_by_user_id: triggered_by_user&.id,
            triggered_by_signal_correlation_id: correlation_id
          )
        end
      end
    end

    def anycast?
      anycast == true
    end

    class StateError < StandardError; end

    private

    def inherit_account_from_network
      return if account_id.present?
      return if sdwan_network_id.blank?

      self.account_id = network&.account_id
    end

    # All holders + failover candidates must belong to the VIP's network.
    # Cross-network holders aren't a thing (different security boundaries).
    def holder_peers_belong_to_network
      return if sdwan_network_id.blank?

      ids = (Array(holder_peer_ids) + Array(failover_holder_peer_ids)).compact.uniq
      return if ids.empty?

      foreign = ::Sdwan::Peer.where(id: ids)
                             .where.not(sdwan_network_id: sdwan_network_id)
                             .pluck(:id)
      return if foreign.empty?

      errors.add(:holder_peer_ids, "contains peers from another network: #{foreign.first(3).join(', ')}")
    end

    # Anycast VIPs need at least 2 holders (a single holder is the
    # active/passive case — that's `anycast: false`).
    def anycast_requires_holder_set
      return unless anycast?
      return if Array(holder_peer_ids).size >= 2

      errors.add(:holder_peer_ids, "anycast VIPs require at least 2 holders")
    end
  end
end
