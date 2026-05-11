# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateFirewallRule < ::System::Executors::Base
      protected

      def perform
        network = ::Sdwan::Network.find(params[:network_id])
        rule = network.firewall_rules.create!(params[:attributes].to_h.symbolize_keys)
        { rule_id: rule.id, network_id: network.id }
      end

      def summarize = "Add firewall rule to SDWAN network #{params[:network_id]}"
    end
  end
end
