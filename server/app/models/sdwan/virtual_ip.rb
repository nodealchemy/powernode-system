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
    self.table_name = "system_sdwan_virtual_ips"

    include Sdwan::LineSafeName

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
    validate :non_anycast_single_holder, if: :will_save_change_to_holder_peer_ids?

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

    # IMP-6c482005db87 — the create-activation rule as ONE symbol for the
    # three sites that must agree: Sdwan::Executors::CreateVirtualIp#perform
    # (the write) and the REST/MCP surfaces' never-saved validation
    # candidates, which must see exactly the row the executor would persist.
    # A VIP created naming holders starts life "active"; a holderless VIP
    # keeps the column-default "pending" until a holder is assigned.
    def activate_if_held
      self.state = "active" if Array(holder_peer_ids).any?
    end

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

        # IMP-43cf1e6b5541 — the demoted holder must be POPPED off, not just
        # left behind the promoted one: subtracting only `new_holder` (which
        # was never in holder_peer_ids to begin with) was a no-op, so
        # old_holder lingered and this produced a size-2 array on a
        # non-anycast VIP, contradicting the doc comment above. Any OTHER
        # stray ids already in the array (pre-existing phantom holders from
        # a different write path) are left alone here — this method's
        # contract is "pop the head", not "normalize the array" — but
        # non_anycast_single_holder now blocks new ones from being written.
        new_holders  = ([ new_holder ] + (Array(holder_peer_ids) - [ new_holder, old_holder ]))
        new_failover = (Array(failover_holder_peer_ids) - [ new_holder ]) + ([ old_holder ].compact)

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

    # IMP-0e44cf2fc80b — the ONE diff-based holder-transition sync for the
    # update surfaces: when holder_peer_ids changes, close out assignments
    # for departed holders and open new ones for arrivals. Reason defaults to
    # "holder_changed" — distinct from "manual_failover" to keep the audit
    # trail honest about what action was taken. Attribution is the CALLER's
    # to name (the copies had already drifted: the REST-gated executor
    # credits the DeferredOperation's requesting user, the MCP tool credits
    # its session user) — so it is a parameter, and the semantics live here
    # once. NOT used by #failover!: that transition is positional (pops the
    # primary, promotes the failover head) and carries signal-correlation
    # attribution — mapping it onto a raw-array diff would also release
    # stray extra holder ids failover! deliberately leaves alone.
    def sync_holder_assignments!(previous_holders, triggered_by_user: nil, reason: "holder_changed")
      # IMP-43cf1e6b5541 — the `.first(1)` truncation for non-anycast VIPs
      # used to be a defense: it kept a stray extra holder id (debris from
      # a write path that produced a size>1 holder_peer_ids on a
      # non-anycast VIP — #failover!'s pre-fix bug was one source) from
      # being diffed at all, which meant it silently NEVER got an
      # assignment history row. That was the phantom-holder defect, not a
      # safety net for one. Now that #non_anycast_single_holder blocks new
      # writes from creating that debris, diffing the full array is safe —
      # and it is what SELF-HEALS any pre-existing stray id: the next real
      # holder-transition sees it as an "arrival" relative to whatever the
      # caller captured as previous_holders and opens its history row (a
      # one-time sweep for debris that won't be touched again soon lives
      # in Sdwan::VirtualIpPhantomHolderBackfillService).
      current = Array(holder_peer_ids).compact

      departed = previous_holders - current
      arrived  = current - previous_holders
      return if departed.empty? && arrived.empty?

      now = Time.current
      departed.each do |peer_id|
        assignments.where(sdwan_peer_id: peer_id, released_at: nil)
                   .update_all(released_at: now, updated_at: now)
      end
      arrived_peers = ::Sdwan::Peer.where(id: arrived).index_by(&:id)
      arrived.each do |peer_id|
        assignments.create!(
          # fetch: an arrival naming a nonexistent peer must fail loudly, as
          # the per-peer find it replaces did.
          peer: arrived_peers.fetch(peer_id),
          assumed_at: now,
          reason: reason,
          triggered_by_user_id: triggered_by_user&.id
        )
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

    # IMP-43cf1e6b5541 — non-anycast VIPs are active/passive: exactly one
    # active holder, not a set (failover_holder_peer_ids is where standby
    # candidates belong). #failover! popping its demoted holder (this same
    # task) is what makes this cap safe to enforce — before that fix, every
    # manual failover on a non-anycast VIP would have raised here.
    #
    # Gated to :will_save_change_to_holder_peer_ids? — ON CHANGE ONLY — so a
    # legacy row already carrying a stray extra holder (written before this
    # validation existed, by a path this task does not touch) doesn't start
    # failing validation on an unrelated field save. Only a fresh write TO
    # holder_peer_ids itself must respect the cap going forward.
    def non_anycast_single_holder
      return if anycast?
      return if Array(holder_peer_ids).size <= 1

      errors.add(:holder_peer_ids, "non-anycast VIPs may have at most one holder (use failover_holder_peer_ids for standby candidates)")
    end
  end
end
