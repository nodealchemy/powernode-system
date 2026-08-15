# frozen_string_literal: true

module Sdwan
  module Executors
    class CreatePortMapping < ::System::Executors::Base
      protected

      def perform
        network = resolve_scoped(::Sdwan::Network, params[:network_id])
        # Account from the resolved network, never from the request:
        # Sdwan::PortMapping belongs_to :account with no inherit-from-network
        # callback, so an unfiltered attributes hash could name any account.
        mapping = network.port_mappings.create!(attrs.merge(account: network.account))
        { mapping_id: mapping.id }
      end

      def summarize = "Add hub DNAT port mapping"
    end
  end
end
