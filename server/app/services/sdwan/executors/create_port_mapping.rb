# frozen_string_literal: true

module Sdwan
  module Executors
    class CreatePortMapping < ::System::Executors::Base
      protected

      def perform
        network = ::Sdwan::Network.find(params[:network_id])
        mapping = network.port_mappings.create!(params[:attributes].to_h.symbolize_keys)
        { mapping_id: mapping.id }
      end

      def summarize = "Add hub DNAT port mapping"
    end
  end
end
