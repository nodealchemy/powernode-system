# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateNetwork < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # No gate site references it today — this executor is composed directly
      # rather than dispatched through Ai::AutonomyGate — but the seeded policy
      # row and the engine registration are pinned to it by
      # spec/services/sdwan/executors/action_category_coherence_spec.rb, so the
      # first surface to gate this verb has a declaration to read.
      ACTION_CATEGORY = "sdwan.network_create"

      protected

      def perform
        network = ::Sdwan::Network.create!(
          attrs.merge(account: account)
        )
        { network_id: network.id, name: network.name }
      end

      def summarize = "Create SDWAN network #{params.dig(:attributes, :name)}"
      def impact    = "Adds a new overlay network — peers can be attached after creation"
    end
  end
end
