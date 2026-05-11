# frozen_string_literal: true

module Sdwan
  module Executors
    # Destructive: cascade-removes peers, route policies, firewall rules.
    class DeleteNetwork < ::System::Executors::Base
      protected

      def perform
        network = ::Sdwan::Network.find(params[:network_id])
        name = network.name
        network.destroy!
        { network_id: params[:network_id], name: name, destroyed: true }
      end

      def summarize
        net = ::Sdwan::Network.find_by(id: params[:network_id])
        net ? "Delete SDWAN network '#{net.name}'" : "Delete SDWAN network"
      end

      def impact = "Cascade-destroys all peers, firewall rules, VIPs, and route policies in this network"
    end
  end
end
