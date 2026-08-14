# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdatePortMapping < ::System::Executors::Base
      protected

      def perform
        mapping = resolve_scoped(::Sdwan::PortMapping, params[:mapping_id])
        # IMP-bf996c7abcb4: hub_belongs_to_network / target_within_network are
        # RELATIVE to the mapping's network, so a foreign sdwan_network_id
        # (plus that network's peers) passes every validation and
        # Sdwan::TopologyCompiler compiles the row into the victim's overlay.
        # Guard semantics live on Base#anchor_reparent! (IMP-0e44cf2fc80b);
        # once the network is anchored, the relative validations transitively
        # anchor the hub and target peers.
        anchor_reparent!(:sdwan_network_id, ::Sdwan::Network)
        mapping.update!(attrs)
        { mapping_id: mapping.id }
      end

      # IMP-3a563becb7d7: name the mapping on the approval card
      # (Ai::DeferredOperationApprovalContent renders preview[:summary]) — the
      # row still exists when the card is composed, and PortMapping validates
      # a name. The sentence matches PortMappingsController#update's gate
      # description verbatim, so the two surfaces naming this one operation
      # cannot disagree (the IMP-ee57d0fbe859 lesson). The bare id is only
      # the floor for a row already gone.
      def summarize
        mapping = ::Sdwan::PortMapping.find_by(id: params[:mapping_id])
        return "Update SDWAN port mapping #{params[:mapping_id]}" unless mapping

        "Update SDWAN port mapping #{mapping.name} on #{mapping.network.name}"
      end

    end
  end
end
