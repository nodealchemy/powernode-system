# frozen_string_literal: true

module System
  module Executors
    module InstancePool
      class UpdatePool < ::System::Executors::Base
        # IMP-24daa05e7a22 — this executor stopped being a producerless
        # sibling when InstancePoolsController#update started routing a
        # CEILING RAISE and the ARCHIVE transition through the gate. Both are
        # spend/teardown decisions replayed at approval time, possibly hours
        # after the request, so the request-time premise has to still hold.
        #
        # target_size / max_size: a raise parks, an operator LOWERS the pool
        # inline in the meantime (decreases are deliberately ungated), and the
        # approval then replays the request verbatim and writes the old high
        # number over the reduction nobody re-approved. status is fingerprinted
        # for the same reason in the other direction — an archive approved
        # after the pool was paused, drained or already archived elsewhere.
        #
        # min_size, description, regions and metadata stay unfingerprinted:
        # they have concurrent writers (the sensor's metadata merge) and a
        # parked edit to them must not be invalidated by a change it expressed
        # no opinion about. #replay_baseline fingerprints only the intersection
        # of this list with what the request actually names.
        def self.replay_baseline_attributes
          %i[target_size max_size status].freeze
        end

        protected

        # resolve_scoped, not a bare `find`: params reach here caller-supplied,
        # stored verbatim in the deferred operation and replayed with no
        # re-validation, which is exactly the threat model Base#resolve_scoped
        # documents. The controller builds pool_id from an account-scoped
        # @pool today, so this closes no live hole — it keeps the executor on
        # the seam its live siblings are on rather than relying on one
        # surface's discipline. (IMP-8e4674f4d62d.)
        def perform
          pool = resolve_scoped(::System::InstancePool, params[:pool_id])
          ::System::InstancePool.transaction do
            # Behind the row lock, not before it: an unlocked read leaves the
            # guard racing the very writer it exists to catch — a decrease
            # landing between the check and the update! passes and is then
            # overwritten. Same placement as Sdwan::Executors::UpdateVirtualIp.
            pool.lock!
            verify_replay_baseline!(pool)
            pool.update!(attrs)
          end
          { pool_id: pool.id }
        end

        # The approval/notification body (Ai::DeferredOperationApprovalContent
        # renders preview[:summary]). Anchored through scoped_label_record for
        # the reason DeletePool is: anchoring makes the no-name arm reachable
        # for a row this account does not own, not just for one already gone,
        # so it has to say which pool the request named.
        def summarize
          pool = scoped_label_record(::System::InstancePool, params[:pool_id])
          pool ? "Update instance pool '#{pool.name}'" : "Update instance pool #{params[:pool_id]}"
        end
      end
    end
  end
end
