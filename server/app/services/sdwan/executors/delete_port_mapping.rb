# frozen_string_literal: true

module Sdwan
  module Executors
    class DeletePortMapping < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.port_mapping_delete"

      protected

      def perform
        mapping = ::Sdwan::PortMapping.find(params[:mapping_id])
        mapping.destroy!
        { mapping_id: params[:mapping_id], destroyed: true }
      end

      def summarize = "Delete port mapping #{params[:mapping_id]}"
    end
  end
end
