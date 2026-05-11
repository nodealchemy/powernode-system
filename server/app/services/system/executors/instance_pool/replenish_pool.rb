# frozen_string_literal: true

module System
  module Executors
    module InstancePool
      class ReplenishPool < ::System::Executors::Base
        protected

        def perform
          pool = ::System::InstancePool.find(params[:pool_id])
          if pool.respond_to?(:replenish!)
            count = pool.replenish!
            { pool_id: pool.id, replenished: count }
          else
            { pool_id: pool.id, replenished: 0 }
          end
        end

        def summarize = "Replenish instance pool #{params[:pool_id]} to target size"
      end
    end
  end
end
