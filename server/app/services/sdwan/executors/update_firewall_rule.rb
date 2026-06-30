# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateFirewallRule < ::System::Executors::Base
      protected

      def perform
        rule = ::Sdwan::FirewallRule.find(params[:rule_id])
        rule.update!(attrs)
        { rule_id: rule.id }
      end

      def summarize = "Update firewall rule #{params[:rule_id]}"
    end
  end
end
