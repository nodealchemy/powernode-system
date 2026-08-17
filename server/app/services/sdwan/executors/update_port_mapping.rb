# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdatePortMapping < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.port_mapping_update"

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
        # IMP-2c531ddb5a0c: the hub is a second caller-writable parent FK, and
        # since this change it is writable from BOTH surfaces (the MCP arm
        # dropped it before). Its refusal used to be derived rather than
        # anchored: hub_belongs_to_network compares the peer's network against
        # the MAPPING's, never against an account, so a foreign hub is refused
        # only because peers are account-aligned with their network — an
        # invariant every write path upholds and no constraint enforces. The
        # comment below already says that about the mapping/network pair; the
        # same gap on the hub is now closed directly, which also means a
        # misaligned peer (right network, wrong account) cannot terminate this
        # account's DNAT. No-op when the attributes name no new hub.
        anchor_reparent!(:sdwan_peer_id, ::Sdwan::Peer)
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
      #
      # IMP-4a5094b22df0: through the same account anchor `perform` resolves by
      # (was a bare `find_by(id:)`). The network is reached THROUGH the anchored
      # mapping — which is safe because every write path keeps the two accounts
      # aligned (CreatePortMapping sets `account: network.account`; this
      # executor's own anchor_reparent!), NOT because the model enforces it:
      # Sdwan::PortMapping validates its hub/target RELATIVE to the network and
      # never compares account_id against the network's. A caller-reachable way
      # to save a misaligned pair would make this name disclosable again.

      def summarize
        mapping = scoped_label_record(::Sdwan::PortMapping, params[:mapping_id])
        return "Update SDWAN port mapping #{params[:mapping_id]}" unless mapping

        "Update SDWAN port mapping #{mapping.name} on #{mapping.network.name}"
      end
    end
  end
end
