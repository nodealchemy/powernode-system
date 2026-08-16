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
    validate :non_anycast_single_holder,
             if: -> { will_save_change_to_holder_peer_ids? || will_save_change_to_anycast? }

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

    # Slice 9b — manual failover for non-anycast VIPs. Normalizes
    # `holder_peer_ids` to the promoted holder alone: pops the head
    # (current primary), pushes it to the back of `failover_holder_peer_ids`,
    # and drops anything else already in holder_peer_ids (debris, never a
    # legitimate second holder outside anycast). Records the assignment
    # transition for every departing holder, not just the primary.
    def failover!(reason: "manual_failover", triggered_by_user: nil, correlation_id: nil)
      # IMP-d952c791e264 — preconditions live in #failover_blocker, the one
      # symbol the pre-gate surfaces share with this method. They used to be
      # two inline raises here, hand-copied into three other places.
      blocker = failover_blocker
      raise StateError, blocker if blocker

      transaction do
        old_holder = Array(holder_peer_ids).first
        new_holder = Array(failover_holder_peer_ids).first

        # IMP-43cf1e6b5541 — normalize to exactly ONE holder, not merely
        # "pop old_holder": non_anycast_single_holder validates every write
        # to holder_peer_ids on THIS SAME update!, so leaving any other
        # stray id in the array (debris predating that validation — e.g.
        # from this method's own pre-fix bug) would make the update raise
        # and roll back, permanently stranding exactly the VIPs this fix is
        # for. Normalizing here instead makes failover! the self-healing
        # recovery path for that debris: any id beyond old_holder is
        # dropped from holder_peer_ids (never added to failover_holder_peer_ids
        # either — it was never a legitimate candidate) and its assignment,
        # if it has one, released alongside old_holder's below.
        stray_ids = Array(holder_peer_ids) - [ old_holder, new_holder ]

        new_holders  = [ new_holder ].compact
        new_failover = (Array(failover_holder_peer_ids) - [ new_holder ]) + ([ old_holder ].compact)

        update!(
          holder_peer_ids: new_holders,
          failover_holder_peer_ids: new_failover.compact,
          state: "active"
        )

        # old_holder is released UNCONDITIONALLY, even when it equals
        # new_holder (a parked candidate-list edit can name the current
        # primary — see Sdwan::Executors::UpdateVirtualIp's replay-baseline
        # comment): release-then-recreate is what lets the create! below
        # avoid colliding with the still-open row on the partial unique
        # index (one active assignment per vip+peer).
        if old_holder
          assignments.where(sdwan_peer_id: old_holder, released_at: nil)
                     .update_all(released_at: Time.current, updated_at: Time.current)
        end
        if stray_ids.any?
          assignments.where(sdwan_peer_id: stray_ids, released_at: nil)
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

    # IMP-d952c791e264 — the ONE answer to "can this VIP fail over, and to
    # which standby". Returns nil when the PRECONDITIONS hold — mode, a
    # non-empty candidate list, and a standby that is a live peer of this
    # VIP's network — or the operator-facing reason the failover is doomed.
    #
    # Preconditions, deliberately, and not a claim that the transaction in
    # #failover! cannot fail for any other reason: a legacy row whose
    # holder_peer_ids debris IS the failover head still collides on the
    # one-active-assignment index down there. That is a bug in the sweep
    # rather than a missing precondition, and is filed separately as
    # recommendation 01a00a28-8ceb-78a5-ae3b-b672d10b5010.
    #
    # Every surface that can start a failover asks this BEFORE doing anything
    # else: Ai::Tools::SdwanTool#failover_virtual_ip and
    # Api::V1::System::Sdwan::VirtualIpsController#failover ask it pre-gate, so
    # a doomed failover is refused inline instead of parking a require_approval
    # DeferredOperation that can only fail hours later at execution;
    # System::Ai::Skills::SdwanVipFailoverExecutor (sensor-driven, ungated)
    # asks it to fail loud; and #failover! raises it as a StateError so the
    # post-approval executor gets the same verdict on state that moved during
    # the approval window. Those were four hand-written copies of two guards,
    # already drifted on wording.
    #
    # The third case none of the copies had: a TOMBSTONE standby.
    # failover_holder_peer_ids is a bare uuid[] with no foreign key,
    # Sdwan::Executors::DeletePeer destroys a peer without scrubbing the arrays
    # that name it, and #holder_peers_belong_to_network only flags ids that
    # EXIST in another network — a deleted id matches no row, so it is not
    # foreign to anything and every check passed it. The failure surfaced at
    # ::Sdwan::Peer.find(new_holder) inside the transaction below.
    #
    # Scoped to the ONE candidate #failover! will promote, not to the whole
    # queue: dead ids further down are not this failover's problem (the head is
    # what gets promoted), and refusing on them would strand a VIP that can
    # still fail over perfectly well.
    def failover_blocker(target_peer_id: nil)
      return "anycast VIPs don't fail over (all holders active simultaneously)" if anycast?
      return "no failover candidates configured — add a standby peer to failover_holder_peer_ids" if Array(failover_holder_peer_ids).empty?

      peer_id = failover_target_peer_id(target_peer_id: target_peer_id)
      # Scoped to THIS VIP's network, not merely to existence: #failover!'s
      # update! re-runs holder_peers_belong_to_network, which rejects a holder
      # from another network — so an unscoped existence check would answer
      # "fine" and then hand the caller an ActiveRecord::RecordInvalid from
      # inside the transaction, the same shape of doomed approval as the
      # tombstone. Reachable the same way: a legacy or update_columns write
      # that predates the validation.
      unless peer_id.present? && network_peer?(peer_id)
        return "failover candidate #{peer_id.presence || '(blank)'} is not a live peer of this VIP's " \
               "network — it was deleted, moved, or never existed; edit the VIP's " \
               "failover_holder_peer_ids to name a current standby"
      end

      nil
    end

    # The candidate #failover! will actually promote: the caller's named target
    # when it is a configured candidate — Sdwan::Executors::FailoverVirtualIp#
    # prefer_target! moves exactly that peer to the head before calling
    # failover!, and no-ops on anything else — otherwise the head of the queue.
    # Kept beside the blocker so "which standby" is answered once, for both the
    # precondition and the promotion it predicts.
    def failover_target_peer_id(target_peer_id: nil)
      candidates = Array(failover_holder_peer_ids)
      return target_peer_id if target_peer_id.present? && candidates.include?(target_peer_id)

      candidates.first
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
    # attribution, not a caller-supplied reason/attribution pair.
    def sync_holder_assignments!(previous_holders, triggered_by_user: nil, reason: "holder_changed")
      # IMP-43cf1e6b5541 — the `.first(1)` truncation for non-anycast VIPs
      # made `current` (computed HERE, post-write) inconsistent with
      # `previous_holders` (the RAW pre-write array the caller captures):
      # on a debris-laden row (a stray id beyond index 0) left untouched by
      # the current write, previous_holders still contained the stray but
      # truncated `current` did not, so the diff spuriously computed the
      # stray as "departed" on every unrelated save — e.g. a bare
      # description edit would release a phantom holder's assignment (if
      # it had one) even though nothing about holders changed. Diffing the
      # untruncated array makes "holders unchanged" a true no-op again.
      #
      # This does NOT, by itself, backfill a missing history row for
      # pre-existing debris: a stray id that was already in BOTH
      # previous_holders and current is diffed as neither departed nor
      # arrived, so no row gets created for it here. It only gets swept up
      # as "departed" (and released, if it had an open assignment) on a
      # write that actually changes holder_peer_ids — #failover! now does
      # the same sweep unconditionally (this same task). Debris on a VIP
      # that never gets touched again needs the one-time sweep in
      # Sdwan::VirtualIpPhantomHolderBackfillService instead.
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

    # IMP-d952c791e264 — the membership test #failover_blocker asks, phrased as
    # the SAME predicate holder_peers_belong_to_network enforces on the write
    # that follows, so the precondition and the validation cannot disagree.
    def network_peer?(peer_id)
      return false if sdwan_network_id.blank?

      ::Sdwan::Peer.where(sdwan_network_id: sdwan_network_id).exists?(id: peer_id)
    end

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
    # candidates belong).
    #
    # Gated ON CHANGE ONLY — to either holder_peer_ids OR anycast — so a
    # legacy row already carrying a stray extra holder (written before this
    # validation existed) doesn't start failing on an unrelated field save.
    # anycast is included because it's the OTHER input to this invariant: an
    # anycast VIP with 2+ holders flipping to anycast: false without also
    # touching holder_peer_ids in the same write would otherwise mint a
    # fresh instance of the exact bug this validation exists to prevent,
    # invisible to a guard keyed on holder_peer_ids alone.
    #
    # #failover! normalizing to one holder unconditionally (this same task)
    # is what makes the holder_peer_ids-only case safe to enforce — before
    # that fix, every manual failover on a non-anycast VIP would have
    # raised here.
    def non_anycast_single_holder
      return if anycast?
      return if Array(holder_peer_ids).size <= 1

      errors.add(:holder_peer_ids, "non-anycast VIPs may have at most one holder (use failover_holder_peer_ids for standby candidates)")
    end
  end
end
