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

        def summarize
          p = ::System::InstancePool.find_by(id: params[:pool_id])
          p ? "Delete instance pool '#{p.name}'" : "Delete instance pool"
        end

        def impact = "Terminates all warm instances + halts replenishment"
      end
    end
  end
end
