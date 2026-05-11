# frozen_string_literal: true

module Sdwan
  module Executors
    class DeletePortMapping < ::System::Executors::Base
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
