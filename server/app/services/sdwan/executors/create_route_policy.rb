# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateRoutePolicy < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.route_policy_create"

      protected

      def perform
        policy = ::Sdwan::RoutePolicy.create!(
          attrs.merge(account: account)
        )
        { policy_id: policy.id, name: policy.try(:name) }
      end

      def summarize = "Create SDWAN route policy"
    end
  end
end
