# frozen_string_literal: true

module Api
  module V1
    module System
      module Network
        # Returns the account's system-wide topology (federation peers +
        # SDWAN networks + bridges + grant summaries) as a node/edge
        # structure for the @xyflow/react canvas at
        # `/app/system/network/topology`.
        #
        # Plan reference: Decentralized Federation §K.5 + P4.5.7.
        class TopologyController < ApplicationController
          before_action :authenticate_request

          def show
            result = ::System::TopologyBuilder.build(account: current_account)
            render_success(
              data: {
                self_id: result.self_id,
                self_label: result.self_label,
                nodes: result.nodes,
                edges: result.edges,
                stats: result.stats
              }
            )
          end

          private

          def current_account
            current_user&.account || Account.find(params[:account_id])
          end
        end
      end
    end
  end
end
