# frozen_string_literal: true

module System
  module Executors
    module InstancePool
      class DeletePool < ::System::Executors::Base
        protected

        def perform
          pool = ::System::InstancePool.find(params[:pool_id])
          name = pool.name
          pool.destroy!
          { pool_id: params[:pool_id], name: name, destroyed: true }
        end

        # IMP-8e4674f4d62d: anchored to the operation's account (was a bare
        # `find_by(id:)`), and the no-name arm carries the id — anchoring makes
        # that arm reachable for a row this account does not own, not just for
        # one already destroyed, so it has to say which pool the request named.
        def summarize
          pool = scoped_label_record(::System::InstancePool, params[:pool_id])
          pool ? "Delete instance pool '#{pool.name}'" : "Delete instance pool #{params[:pool_id]}"
        end

        # Replenishment ends with the row — the reaper lists pools from the
        # API and a destroyed pool is never returned (and replenish! refuses
        # any non-active pool anyway, IMP-cb2da06a384b).
        #
        # It does NOT terminate anything, and this card used to say it did.
        # #perform is `pool.destroy!`; node_instances is `dependent: :nullify`,
        # so surviving members are DETACHED from the pool and their VMs keep
        # running (and billing) with no pool left to recycle them. The MCP
        # verb refuses outright while members remain
        # (SystemFleetTool#delete_instance_pool) — this gated REST path does
        # not, which is what makes the difference worth stating on the card.
        def impact
          "Deletes the pool + ends its replenishment; member VMs are NOT " \
            "terminated — surviving members are detached and keep running"
        end
      end
    end
  end
end
