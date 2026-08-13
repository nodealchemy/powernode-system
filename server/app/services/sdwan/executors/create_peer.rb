# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.peer_create` — adds a peer to a SDWAN network.
    # Most peer creates are auto-approved (additive operation), but the
    # AutonomyGate audit row + chain-of-custody is still useful.
    class CreatePeer < ::System::Executors::Base
      protected

      def perform
        network = ::Sdwan::Network.find(params[:network_id])
        peer = network.peers.create!(attrs)
        # IMP-ee57d0fbe859: record the connectivity tuple in the same shape
        # Sdwan::Executors::DeletePeer records on removal. This read
        # `peer.try(:endpoint)` — Sdwan::Peer has no `endpoint` method or column,
        # so every create row reported endpoint: nil and no auditor could
        # correlate "which endpoint was added" with "which endpoint was removed".
        { peer_id: peer.id, network_id: network.id, endpoint: peer.primary_endpoint }
      end

      # IMP-1eba7d50d24c: this is the approval/notification body
      # (Ai::DeferredOperationApprovalContent.title and .message both render
      # preview[:summary]). It read "Add SDWAN peer to network <uuid>" — a bare
      # network UUID, and no mention of the peer at all — while the matching
      # delete card reads "Delete SDWAN peer edge-lon-01 on wan-core", so the
      # two rows for one peer did not visibly concern the same network.
      #
      # The peer does not exist yet, so the label is composed from what the
      # request already names, through Sdwan::Peer.operator_label_for — the same
      # ladder DeletePeer renders afterwards.
      def summarize
        label = ::Sdwan::Peer.operator_label_for(
          node_instance: target_node_instance,
          network_name: network_label,
          endpoint_display: prospective_endpoint_display,
          fallback: attrs[:node_instance_id]
        )
        return "Add SDWAN peer #{label}" if label.present?
        return "Add SDWAN peer to network #{network_label}" if network_label.present?

        "Add SDWAN peer"
      end

      def impact
        "Onboards a new node into the overlay network"
      end

      private

      # The account the peer will belong to. Deliberately NOT the `account`
      # helper: that reads deferred_operation.account, and the only path that
      # reaches this label is Base.preview, which builds the executor with
      # deferred_operation: nil — consulting it would be an arm nothing can
      # execute. The create attributes carry the account instead, and must:
      # Sdwan::Peer belongs_to :account, so `network.peers.create!(attrs)`
      # without one raises. Absent an account id the lookups are skipped rather
      # than run unscoped — an approval card must not name another account's rows.
      def target_account_id
        attrs[:account_id]
      end

      def target_network
        return @target_network if defined?(@target_network)

        @target_network =
          if target_account_id.present? && params[:network_id].present?
            ::Sdwan::Network.find_by(id: params[:network_id], account_id: target_account_id)
          end
      end

      def network_label
        target_network&.name.presence || params[:network_id]
      end

      def target_node_instance
        return @target_node_instance if defined?(@target_node_instance)

        instance_id = attrs[:node_instance_id]
        @target_node_instance =
          if target_account_id.present? && instance_id.present?
            # NodeInstance has no account_id column — account flows through node.
            ::System::NodeInstance.joins(:node)
                                  .where(system_nodes: { account_id: target_account_id })
                                  .find_by(id: instance_id)
          end
      end

      # The endpoint rung, rendered by the peer's own formatter (v6-literal
      # bracketing included) off an unsaved row carrying only the endpoint
      # columns the request supplied — never a second copy of the format.
      def prospective_endpoint_display
        ::Sdwan::Peer.new(
          endpoint_host_v6: attrs[:endpoint_host_v6],
          endpoint_host_v4: attrs[:endpoint_host_v4],
          endpoint_host: attrs[:endpoint_host],
          endpoint_port: attrs[:endpoint_port]
        ).endpoint_display
      end
    end
  end
end
