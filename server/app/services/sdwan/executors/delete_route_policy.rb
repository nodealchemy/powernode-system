# frozen_string_literal: true

module Sdwan
  module Executors
    class DeleteRoutePolicy < ::System::Executors::Base
      protected

      # IMP-4a5094b22df0: `resolve_scoped`, matching its UpdateRoutePolicy
      # sibling. This was a bare `find`, so the DESTROY itself rested entirely
      # on Ai::DeferredOperation#assert_source_within_account! — which covers
      # this path only because the one gated dispatcher happens to record
      # source_type/source_id, and only ever covers the recorded pair. Not
      # exploitable through today's dispatcher (RoutePoliciesController#destroy
      # pre-scopes in set_policy), but a guard that depends on every present and
      # future caller recording the right source is not a guard.
      def perform
        policy = resolve_scoped(::Sdwan::RoutePolicy, params[:policy_id])
        name = policy.name
        policy.destroy!
        { policy_id: params[:policy_id], name: name, destroyed: true }
      end

      # IMP-3a563becb7d7: name the policy on the approval card
      # (Ai::DeferredOperationApprovalContent renders preview[:summary]) — the
      # row still exists when the card is composed, and RoutePolicy validates
      # a name. The bare id is only the floor for a row already gone.
      #
      # IMP-4a5094b22df0: anchored to the operation's account, so the sentence
      # and the destroy resolve the same param through the same scope.
      def summarize
        policy = scoped_label_record(::Sdwan::RoutePolicy, params[:policy_id])
        return "Delete route policy #{params[:policy_id]}" unless policy

        "Delete route policy '#{policy.name}'"
      end

      def impact = "Removes BGP route filtering — neighbor advertisements may shift"
    end
  end
end
