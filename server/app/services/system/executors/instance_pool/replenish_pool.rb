# frozen_string_literal: true

module System
  module Executors
    module InstancePool
      class ReplenishPool < ::System::Executors::Base
        protected

        def perform
          pool = ::System::InstancePool.find(params[:pool_id])
          # replenish! is an InstancePoolService class method (pool: kwarg),
          # not a model method — the previous respond_to?(:replenish!) guard
          # was always false, so this executor silently no-opped.
          result = ::System::InstancePoolService.replenish!(pool: pool)
          { pool_id: pool.id, replenished: result[:provisioned] }
        end

        def summarize = "Replenish instance pool #{params[:pool_id]} to target size"
      end
    end
  end
end
