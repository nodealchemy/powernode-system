# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateRoutePolicy < ::System::Executors::Base
      protected

      def perform
        policy = resolve_scoped(::Sdwan::RoutePolicy, params[:policy_id])
        policy.update!(attrs)
        { policy_id: policy.id }
      end

      def summarize = "Update route policy #{params[:policy_id]}"
    end
  end
end
