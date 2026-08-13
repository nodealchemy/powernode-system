# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdatePortMapping < ::System::Executors::Base
      protected

      def perform
        mapping = resolve_scoped(::Sdwan::PortMapping, params[:mapping_id])
        anchor_reparent!
        mapping.update!(attrs)
        { mapping_id: mapping.id }
      end

      def summarize = "Update port mapping #{params[:mapping_id]}"

      private

      # IMP-bf996c7abcb4: `attrs` drops account/account_id, which stops the
      # tenancy MOVE but not the tenancy RE-PARENT. sdwan_network_id is equally
      # tenancy-bearing here, and Sdwan::PortMapping's own guards are RELATIVE:
      # hub_belongs_to_network and target_within_network compare the hub/target
      # against the mapping's network, never against this operation's account.
      # A payload naming a foreign network AND that same network's peers
      # therefore satisfies every model validation while account_id stays the
      # caller's — and Sdwan::TopologyCompiler compiles the row into the
      # victim's overlay.
      #
      # Resolving the new parent through resolve_scoped is the whole guard:
      # in-account re-parents still work, and once the network is anchored the
      # relative validations transitively anchor the hub and target peers,
      # since a peer can only satisfy them by belonging to that same network.
      # When no new parent is named, the mapping's existing network is already
      # covered by the resolve_scoped above.
      def anchor_reparent!
        network_id = attrs[:sdwan_network_id]
        return if network_id.blank?

        resolve_scoped(::Sdwan::Network, network_id)
      end
    end
  end
end
