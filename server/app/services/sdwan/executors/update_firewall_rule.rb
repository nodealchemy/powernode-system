# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateFirewallRule < ::System::Executors::Base
      protected

      # IMP-0e44cf2fc80b — the port_range → port_range_hash re-key fires on
      # BOTH the immediate (:proceed) and the approved (execute_now!) path:
      # gate! / gated_result never invoke their proceed blocks on :pending,
      # the gate parks the API's {from:, to:} :port_range shape verbatim, and
      # the raw column is an int4range a Hash cannot set. The re-key itself
      # lives on the model (Sdwan::FirewallRule#port_range=, including the
      # IMP-32978416b9d3 {}/nil clearing nuance), so this update! needs no
      # local transform — mass assignment routes :port_range through it.
      def perform
        rule = resolve_scoped(::Sdwan::FirewallRule, params[:rule_id])
        # Sdwan::FirewallRule's validations are RELATIVE to the rule's
        # network (name uniqueness, selector checks — none consult an
        # account, and inherit_account_from_network only fires when
        # account_id is blank), so a foreign sdwan_network_id keeps the
        # caller's account while Sdwan::FirewallCompiler compiles the row
        # into the victim network's nft chain. Guard semantics live on
        # Base#anchor_reparent! (IMP-0e44cf2fc80b).
        anchor_reparent!(:sdwan_network_id, ::Sdwan::Network)
        rule.update!(attrs)
        { rule_id: rule.id }
      end

      # IMP-3a563becb7d7 convention: #summarize is the approval/notification
      # body (Ai::DeferredOperationApprovalContent renders preview[:summary]),
      # and the sentence matches FirewallRulesController#update's gate
      # description verbatim so the two surfaces naming this one operation
      # cannot disagree (the IMP-ee57d0fbe859 lesson, UpdatePortMapping
      # precedent). The bare id is only the floor for a row already gone.
      def summarize
        rule = ::Sdwan::FirewallRule.find_by(id: params[:rule_id])
        return "Update firewall rule #{params[:rule_id]}" unless rule

        "Update firewall rule '#{rule.name}' on SDWAN network #{rule.network.name}"
      end
    end
  end
end
