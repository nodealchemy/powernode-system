# frozen_string_literal: true

module System
  module Executors
    module InstancePool
      class DrainPool < ::System::Executors::Base
        protected

        def perform
          pool = ::System::InstancePool.find(params[:pool_id])
          if pool.respond_to?(:drain!)
            count = pool.drain!
            { pool_id: pool.id, drained: count }
          else
            { pool_id: pool.id, drained: 0 }
          end
        end

        def summarize = "Drain instance pool #{params[:pool_id]}"
        def impact    = "Halts replenishment + terminates ready members; in-use members untouched"
      end
    end
  end
end
