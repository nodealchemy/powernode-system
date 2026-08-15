# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.peer_create` — adds a peer to a SDWAN network.
    # Most peer creates are auto-approved (additive operation), but the
    # AutonomyGate audit row + chain-of-custody is still useful.
    class CreatePeer < ::System::Executors::Base
      protected

      def perform
        network = resolve_scoped(::Sdwan::Network, params[:network_id])
        # IMP-2d26f7289c38 PHASE 0: the account comes from the resolved network,
        # never from the request. Sdwan::Peer belongs_to :account with no
        # inherit-from-network callback, and account_id was mass-assignable
        # straight out of params[:attributes] — which the gate stores verbatim
        # and replays unvalidated at approval time.
        peer = network.peers.create!(attrs.merge(account: network.account))
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

      # IMP-97bb6231a322: the account this label may name rows from.
      #
      # It was `requested_account_id` — params[:attributes][:account_id], read
      # out of the one hash `attrs` deliberately strips the tenancy keys from.
      # The earlier reasoning ("assignment-unsafe, but scoping a read by them is
      # not") does not hold: an id the caller supplies cannot be trusted to
      # SELECT an owner any more than to assign one. It cut both ways — a
      # request naming a victim's account had the victim's network and node
      # instance resolved and their NAMES rendered onto the requester's own card
      # and into the Ai::ApprovalRequest body, while every honest request (no
      # dispatcher puts account_id in `attributes`) anchored on nil, skipped both
      # lookups and degraded to the bare UUIDs IMP-1eba7d50d24c removed.
      #
      # Two anchors instead, in precedence order:
      #
      #   1. the OPERATION's account — the gate opened the operation in it, so
      #      it is the one account on this request nobody supplied. LIVE as of
      #      IMP-4a5094b22df0: Ai::DeferredOperation#preview now threads itself
      #      through Base.preview, so every card composed for a gated peer
      #      create anchors here. (Peer creation has no gated dispatcher yet —
      #      it runs through Sdwan::PeerEnroller — so "every card" is still
      #      none; this arm is correct and waiting, not exercised in production.)
      #      It closes the residual this comment used to end on: a requester
      #      holding a foreign network id AND a node-instance id from that SAME
      #      foreign account no longer gets either row named, because arm 2
      #      never runs once arm 1 answers.
      #   2. otherwise the account of the network the request NAMES — a row's
      #      own owner, not a claim — corroborated by the node instance the SAME
      #      request names. One caller-supplied id is not corroboration for
      #      another, so when the two rows disagree the card names neither and
      #      falls back to ids. That keeps a card from ever mixing two accounts'
      #      names, which is the guarantee IMP-1eba7d50d24c was really after.
      #      It remains the anchor for a PRE-GATE preview, which has no
      #      operation to read an account from.
      def target_account_id
        return @target_account_id if defined?(@target_account_id)

        @target_account_id = account&.id || corroborated_account_id
      end

      def corroborated_account_id
        network_owner = named_network&.account_id
        return nil if network_owner.blank?
        return nil unless named_node_instance&.account_id == network_owner

        network_owner
      end

      # Resolved by id ALONE: on the preview path this row carries the anchor,
      # so it cannot itself be scoped by one. Nothing is named off either row
      # until `target_account_id` has settled and the row is checked against it.
      def named_network
        return @named_network if defined?(@named_network)

        @named_network =
          params[:network_id].present? ? ::Sdwan::Network.find_by(id: params[:network_id]) : nil
      end

      # system_node_instances carries account_id as a NOT NULL column, kept
      # equal to the parent node's by System::NodeInstance#account_matches_node
      # — the comment that used to sit here ("no account_id column — account
      # flows through node") described the schema before that denormalization.
      def named_node_instance
        return @named_node_instance if defined?(@named_node_instance)

        instance_id = attrs[:node_instance_id]
        @named_node_instance =
          instance_id.present? ? ::System::NodeInstance.find_by(id: instance_id) : nil
      end

      def target_network
        anchor = target_account_id
        return nil if anchor.blank?

        named_network if named_network&.account_id == anchor
      end

      def network_label
        target_network&.name.presence || params[:network_id]
      end

      def target_node_instance
        anchor = target_account_id
        return nil if anchor.blank?

        named_node_instance if named_node_instance&.account_id == anchor
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
