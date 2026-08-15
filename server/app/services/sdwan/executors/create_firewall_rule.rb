# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateFirewallRule < ::System::Executors::Base
      protected

      def perform
        network = resolve_scoped(::Sdwan::Network, params[:network_id])
        rule = network.firewall_rules.create!(attrs)
        { rule_id: rule.id, network_id: network.id }
      end

      # IMP-3a563becb7d7: this is the approval/notification body
      # (Ai::DeferredOperationApprovalContent.title and .message both render
      # preview[:summary]). It read "Add firewall rule to SDWAN network
      # <uuid>" — a bare network UUID, naming neither the rule nor a network
      # the operator recognises. The rule does not exist yet, so the card is
      # composed from what the request already names, mirroring CreatePeer
      # (IMP-1eba7d50d24c).
      def summarize
        rule_name = attrs[:name].presence
        label = network_label.presence
        [
          "Add firewall rule",
          ("'#{rule_name}'" if rule_name),
          ("to SDWAN network #{label}" if label)
        ].compact.join(" ")
      end

      private

      # IMP-4a5094b22df0: anchored to the OPERATION's account. It was scoped by
      # `requested_account_id` — params[:attributes][:account_id], read out of
      # the one hash `attrs` strips the tenancy keys from before any write — and
      # that cut both ways (the CreatePeer analysis, IMP-97bb6231a322): a
      # request naming a victim's account had the victim's network resolved and
      # its NAME rendered onto the requester's card, while every honest request
      # anchored on nil and degraded to the bare UUID IMP-1eba7d50d24c set out
      # to remove. Neither half was reachable through the sole dispatcher, which
      # stamps the authenticated account server-side — a latent hole waiting on
      # a second dispatcher, closed here because the operation carries the one
      # account on the request nobody supplied.
      #
      # Skipping rather than running unscoped when there is no anchor is
      # Base#scoped_label_record's contract now, not this file's.
      def target_network
        return @target_network if defined?(@target_network)

        @target_network = scoped_label_record(::Sdwan::Network, params[:network_id])
      end

      def network_label
        target_network&.name.presence || params[:network_id]
      end
    end
  end
end
