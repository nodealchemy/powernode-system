# frozen_string_literal: true

module System
  module Executors
    module InstancePool
      class CreatePool < ::System::Executors::Base
        protected

        def perform
          pool = ::System::InstancePool.create!(
            params[:attributes].to_h.symbolize_keys.merge(account: account)
          )
          { pool_id: pool.id, name: pool.name, target_size: pool.try(:target_size) }
        end

        def summarize = "Create instance pool #{params.dig(:attributes, :name)}"
        def impact    = "Reserves capacity — instances begin pre-provisioning to target size"
      end
    end
  end
end
