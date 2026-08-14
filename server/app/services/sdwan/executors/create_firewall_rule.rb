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

      # Scoped to the account the create attributes carry: deferred_operation
      # is nil on the preview path (Base.preview hardcodes it), and absent an
      # account id the lookup is skipped rather than run unscoped — an
      # approval card must not name another account's rows (IMP-1eba7d50d24c).
      def target_network
        return @target_network if defined?(@target_network)

        @target_network =
          if requested_account_id.present? && params[:network_id].present?
            ::Sdwan::Network.find_by(id: params[:network_id], account_id: requested_account_id)
          end
      end

      def network_label
        target_network&.name.presence || params[:network_id]
      end
    end
  end
end
