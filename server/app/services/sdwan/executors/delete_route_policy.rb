# frozen_string_literal: true

module Sdwan
  module Executors
    class DeleteRoutePolicy < ::System::Executors::Base
      protected

      def perform
        policy = ::Sdwan::RoutePolicy.find(params[:policy_id])
        name = policy.name
        policy.destroy!
        { policy_id: params[:policy_id], name: name, destroyed: true }
      end

      # IMP-3a563becb7d7: name the policy on the approval card
      # (Ai::DeferredOperationApprovalContent renders preview[:summary]) — the
      # row still exists when the card is composed, and RoutePolicy validates
      # a name. The bare id is only the floor for a row already gone.
      def summarize
        policy = ::Sdwan::RoutePolicy.find_by(id: params[:policy_id])
        return "Delete route policy #{params[:policy_id]}" unless policy

        "Delete route policy '#{policy.name}'"
      end

      def impact = "Removes BGP route filtering — neighbor advertisements may shift"
    end
  end
end
