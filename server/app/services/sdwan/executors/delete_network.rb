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

      # IMP-8e4674f4d62d: anchored to the operation's account (was a bare
      # `find_by(id:)`), so a caller that did not pre-scope cannot have another
      # account's network named on its approvers' card.
      #
      # The no-name arm carries the id now. It was reachable only for a row
      # already destroyed, and read "Delete SDWAN network" — nothing an
      # approver could act on. Anchoring makes it reachable a second way (a row
      # this account does not own), so the floor has to say WHICH network the
      # request was about, which is the caller contract #scoped_label_record
      # documents: nil means render the id, never "not found".
      def summarize
        net = scoped_label_record(::Sdwan::Network, params[:network_id])
        net ? "Delete SDWAN network '#{net.name}'" : "Delete SDWAN network #{params[:network_id]}"
      end

      def impact = "Cascade-destroys all peers, firewall rules, VIPs, and route policies in this network"
    end
  end
end
