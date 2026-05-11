# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdatePortMapping < ::System::Executors::Base
      protected

      def perform
        mapping = ::Sdwan::PortMapping.find(params[:mapping_id])
        mapping.update!(params[:attributes].to_h.symbolize_keys)
        { mapping_id: mapping.id }
      end

      def summarize = "Update port mapping #{params[:mapping_id]}"
    end
  end
end
