# frozen_string_literal: true

# Operator-facing read API for Sdwan::IpfixCollector. Read-only —
# creation happens through the SdwanIpfixCollectorComposeExecutor AI
# skill or the system_sdwan_create_ipfix_collector MCP action.
#
# Each row carries an `is_winning_collector` flag in the serialized
# shape: the topology compiler picks the account's oldest active
# collector when stamping the ipfix payload onto OVS bridges, so a
# fleet can have multiple collectors but only one wires up. Surfacing
# the flag here lets operators see at a glance which row will
# actually be used.
#
# Phase O6 of the OVS+OVN dual-profile networking roadmap.
module Api
  module V1
    module System
      module Sdwan
        class IpfixCollectorsController < ::Api::V1::System::BaseController
          before_action :set_account
          before_action :set_collector, only: %i[show update destroy]

          def index
            require_permission("sdwan.ipfix.read")

            scope = ::Sdwan::IpfixCollector.for_account(@account)
            scope = scope.where(state: params[:state]) if params[:state].present?

            collectors = scope.order(:created_at).to_a
            winning_id = winning_collector_id

            render_success(
              ipfix_collectors: collectors.map { |c| serialize_collector(c, winning_id: winning_id) },
              count: collectors.size,
              filters: { state: params[:state] }.compact
            )
          end

          def show
            require_permission("sdwan.ipfix.read")
            render_success(ipfix_collector: serialize_collector_full(@collector))
          end

          def update
            require_permission("sdwan.ipfix.manage")

            target = params.dig(:ipfix_collector, :state) || params[:state]
            case target.to_s
            when "active"   then @collector.enable!
            when "disabled" then @collector.disable!
            else
              return render_error("state must be 'active' or 'disabled'", status: :unprocessable_entity)
            end

            render_success(ipfix_collector: serialize_collector_full(@collector.reload))
          end

          def destroy
            require_permission("sdwan.ipfix.manage")
            @collector.destroy!
            render_success(deleted: true, id: @collector.id)
          end

          private

          def set_collector
            @collector = ::Sdwan::IpfixCollector.where(account_id: @account.id)
                                                .find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN IPFIX Collector")
          end

          # Computed once per request — index walks every collector but
          # the winner lookup runs once. O(n+1) to O(n+1) tradeoff is
          # fine since n is tiny (operators rarely run >5 collectors).
          def winning_collector_id
            @winning_collector_id ||=
              ::Sdwan::IpfixCollector.for_account(@account).active.order(:created_at).first&.id
          end

          def serialize_collector(c, winning_id:)
            {
              id: c.id,
              name: c.name,
              host: c.host,
              port: c.port,
              target_endpoint: c.target_endpoint,
              sampling_rate: c.sampling_rate,
              state: c.state,
              is_winning_collector: c.id == winning_id
            }
          end

          def serialize_collector_full(c)
            serialize_collector(c, winning_id: winning_collector_id).merge(
              created_at: c.created_at.iso8601,
              updated_at: c.updated_at.iso8601
            )
          end
        end
      end
    end
  end
end
