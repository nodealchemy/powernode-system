# frozen_string_literal: true

module Sdwan
  module Executors
    class DeleteRoutePolicy < ::System::Executors::Base
      protected

      def perform
        policy = ::Sdwan::RoutePolicy.find(params[:policy_id])
        name = policy.try(:name)
        policy.destroy!
        { policy_id: params[:policy_id], name: name, destroyed: true }
      end

      def summarize = "Delete route policy #{params[:policy_id]}"
      def impact    = "Removes BGP route filtering — neighbor advertisements may shift"
    end
  end
end
