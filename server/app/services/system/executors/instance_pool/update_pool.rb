# frozen_string_literal: true

module System
  module Executors
    module InstancePool
      class UpdatePool < ::System::Executors::Base
        protected

        def perform
          pool = ::System::InstancePool.find(params[:pool_id])
          pool.update!(params[:attributes].to_h.symbolize_keys)
          { pool_id: pool.id }
        end

        def summarize = "Update instance pool #{params[:pool_id]}"
      end
    end
  end
end
