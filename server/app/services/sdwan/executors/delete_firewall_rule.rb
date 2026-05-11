# frozen_string_literal: true

module Sdwan
  module Executors
    class DeleteFirewallRule < ::System::Executors::Base
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
