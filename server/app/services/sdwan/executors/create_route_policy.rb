# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateRoutePolicy < ::System::Executors::Base
      protected

      def perform
        policy = ::Sdwan::RoutePolicy.create!(
          params[:attributes].to_h.symbolize_keys.merge(account: account)
        )
        { policy_id: policy.id, name: policy.try(:name) }
      end

      def summarize = "Create SDWAN route policy"
    end
  end
end
