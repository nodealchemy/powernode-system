# frozen_string_literal: true

# Sdwan::VirtualIpPhantomHolderBackfillService — IMP-43cf1e6b5541: before
# this task's on-change validation (Sdwan::VirtualIp#non_anycast_single_holder)
# and #failover! fix landed, a non-anycast VirtualIp could accumulate a
# stray extra holder id in holder_peer_ids (the classic case: #failover!
# failed to pop the demoted holder) with no corresponding
# Sdwan::VirtualIpAssignment row — a phantom holder, invisible to the
# assignment audit trail.
#
# #sync_holder_assignments! self-heals this the NEXT time a VIP's
# holder_peer_ids genuinely changes (removing the `.first(1)` truncation,
# also part of this task, was the only thing hiding stray ids from its
# diff). This service is the one-time (idempotent — safe to re-run) sweep
# for VIPs that won't necessarily be touched again soon, invoked via
# `rake sdwan:backfill_phantom_vip_holders`. Shape mirrors
# Sdwan::VrfBackfillService (IMP-07014982a6d3), the precedent for a
# one-time backfill of pre-existing fleet debris.
module Sdwan
  class VirtualIpPhantomHolderBackfillService
    Result = Struct.new(:backfilled_count, :errors, keyword_init: true)

    def self.call
      new.call
    end

    def call
      backfilled = 0
      errors = []

      ::Sdwan::VirtualIp.where(anycast: false).find_each do |vip|
        # index 0 is the primary holder — the one #failover!/sync already
        # keep attributed. Anything beyond it on a non-anycast VIP is, by
        # definition, stray debris this task's validation now forbids
        # writing anew.
        stray_ids = Array(vip.holder_peer_ids).drop(1).uniq
        next if stray_ids.empty?

        stray_ids.each do |peer_id|
          next if ::Sdwan::VirtualIpAssignment.exists?(
            sdwan_virtual_ip_id: vip.id, sdwan_peer_id: peer_id, released_at: nil
          )

          begin
            peer = ::Sdwan::Peer.find(peer_id)
            vip.assignments.create!(
              peer: peer,
              # The true assumed_at is unknown — this is a reconciliation,
              # not a live event — so the VIP's own last write is the
              # closest honest anchor.
              assumed_at: vip.updated_at,
              reason: "phantom_backfill"
            )
            backfilled += 1
          rescue StandardError => e
            errors << "vip=#{vip.id} peer=#{peer_id}: #{e.class}: #{e.message}"
          end
        end
      end

      Result.new(backfilled_count: backfilled, errors: errors)
    end
  end
end
