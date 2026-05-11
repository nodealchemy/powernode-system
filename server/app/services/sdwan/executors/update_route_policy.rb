# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateRoutePolicy < ::System::Executors::Base
      protected

      def perform
        policy = ::Sdwan::RoutePolicy.find(params[:policy_id])
        policy.update!(params[:attributes].to_h.symbolize_keys)
        { policy_id: policy.id }
      end

      def summarize = "Update route policy #{params[:policy_id]}"
    end
  end
end
