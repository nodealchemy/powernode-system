# frozen_string_literal: true

module Sdwan
  module Executors
    class DeleteFirewallRule < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.firewall_rule_delete"

      protected

      def perform
        rule = ::Sdwan::FirewallRule.find(params[:rule_id])
        rule.destroy!
        { rule_id: params[:rule_id], destroyed: true }
      end

      def summarize = "Delete firewall rule #{params[:rule_id]}"
      def impact    = "Removes traffic filter — connectivity may shift"
    end
  end
end
