# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateNetwork < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.network_update"

      protected

      def perform
        network = resolve_scoped(::Sdwan::Network, params[:network_id])
        network.update!(attrs)
        { network_id: network.id }
      end

      def summarize = "Update SDWAN network #{params[:network_id]}"
    end
  end
end
