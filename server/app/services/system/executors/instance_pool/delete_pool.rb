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

        def impact = "Terminates all warm instances + halts replenishment"
      end
    end
  end
end
