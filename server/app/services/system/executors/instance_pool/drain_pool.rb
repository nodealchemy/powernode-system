# frozen_string_literal: true

module System
  module Executors
    module InstancePool
      class DrainPool < ::System::Executors::Base
        protected

        def perform
          pool = ::System::InstancePool.find(params[:pool_id])
          # drain! is an InstancePoolService class method (pool: kwarg), not a
          # model method — the previous respond_to?(:drain!) guard was always
          # false, so this executor silently no-opped.
          result = ::System::InstancePoolService.drain!(pool: pool)
          { pool_id: pool.id, drained: result[:drained] }
        end

        def summarize = "Drain instance pool #{params[:pool_id]}"
        def impact    = "Halts replenishment + terminates ready members; in-use members untouched"
      end
    end
  end
end
