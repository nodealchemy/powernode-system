# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateNetwork < ::System::Executors::Base
      protected

      def perform
        network = ::Sdwan::Network.find(params[:network_id])
        network.update!(params[:attributes].to_h.symbolize_keys)
        { network_id: network.id }
      end

      def summarize = "Update SDWAN network #{params[:network_id]}"
    end
  end
end
