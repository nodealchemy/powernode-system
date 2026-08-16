# frozen_string_literal: true

module Sdwan
  module Executors
    class CreatePortMapping < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.port_mapping_create"

      protected

      def perform
        network = resolve_scoped(::Sdwan::Network, params[:network_id])
        # Account from the resolved network, never from the request:
        # Sdwan::PortMapping belongs_to :account with no inherit-from-network
        # callback, so an unfiltered attributes hash could name any account.
        mapping = network.port_mappings.create!(attrs.merge(account: network.account))
        { mapping_id: mapping.id }
      end

      def summarize = "Add hub DNAT port mapping"
    end
  end
end
