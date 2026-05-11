# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateNetwork < ::System::Executors::Base
      protected

      def perform
        network = ::Sdwan::Network.create!(
          params[:attributes].to_h.symbolize_keys.merge(account: account)
        )
        { network_id: network.id, name: network.name }
      end

      def summarize = "Create SDWAN network #{params.dig(:attributes, :name)}"
      def impact    = "Adds a new overlay network — peers can be attached after creation"
    end
  end
end
