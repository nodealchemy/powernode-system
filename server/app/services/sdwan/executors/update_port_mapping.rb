# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdatePortMapping < ::System::Executors::Base
      protected

      def perform
        mapping = resolve_scoped(::Sdwan::PortMapping, params[:mapping_id])
        mapping.update!(attrs)
        { mapping_id: mapping.id }
      end

      def summarize = "Update port mapping #{params[:mapping_id]}"
    end
  end
end
