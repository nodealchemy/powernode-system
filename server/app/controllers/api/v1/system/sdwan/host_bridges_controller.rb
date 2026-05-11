# frozen_string_literal: true

# Operator-facing read API for Sdwan::HostBridge. Read-only — allocation
# happens through Sdwan::HostBridgeAllocator (the source-of-truth atomic
# allocator) which is invoked by the on-node agent during reconcile, by
# the SdwanHostBridgeComposeExecutor AI skill for batch composition, or
# by the system_sdwan_create_host_bridge MCP action for one-off operator
# allocation. This controller exists so an operator UI (or external
# tooling like Postman) can inspect the resulting rows.
#
# Phase O6 of the OVS+OVN dual-profile networking roadmap.
module Api
  module V1
    module System
      module Sdwan
        class HostBridgesController < ::Api::V1::System::BaseController
          before_action :set_account
          before_action :set_bridge, only: %i[show destroy]

          def index
            require_permission("sdwan.host_bridges.read")

            scope = ::Sdwan::HostBridge
                      .where(account_id: @account.id)
                      .includes(:node_instance)

            scope = scope.where(node_instance_id: params[:node_instance_id]) if params[:node_instance_id].present?
            scope = scope.where(state: params[:state])                        if params[:state].present?
            scope = scope.where(kind:  params[:kind])                         if params[:kind].present?

            bridges = scope.order(:node_instance_id, :short_id).to_a

            render_success(
              host_bridges: bridges.map { |b| serialize_bridge(b) },
              count: bridges.size,
              filters: {
                node_instance_id: params[:node_instance_id],
                state: params[:state],
                kind:  params[:kind]
              }.compact
            )
          end

          def show
            require_permission("sdwan.host_bridges.read")
            render_success(host_bridge: serialize_bridge_full(@bridge))
          end

          def destroy
            require_permission("sdwan.host_bridges.manage")
            # Release via the allocator with force: true so the short_id
            # returns to the pool immediately (rather than entering the
            # draining grace window). Operators using inline UI delete
            # know what they're doing; the grace window is for the
            # autonomous reconcile path.
            ::Sdwan::HostBridgeAllocator.release!(@bridge, force: true)
            render_success(deleted: true, id: @bridge.id)
          end

          private

          def set_bridge
            @bridge = ::Sdwan::HostBridge.where(account_id: @account.id)
                                         .includes(:node_instance)
                                         .find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Host Bridge")
          end

          def serialize_bridge(b)
            instance = b.node_instance
            {
              id: b.id,
              node_instance_id: b.node_instance_id,
              node_instance_name: instance&.name,
              network_profile: instance&.network_profile,
              short_id: b.short_id,
              bridge_name: b.bridge_name,
              kind: b.kind,
              state: b.state
            }
          end

          def serialize_bridge_full(b)
            serialize_bridge(b).merge(
              applied_at:  b.applied_at&.iso8601,
              draining_at: b.draining_at&.iso8601,
              removed_at:  b.removed_at&.iso8601,
              created_at:  b.created_at.iso8601,
              updated_at:  b.updated_at.iso8601
            )
          end
        end
      end
    end
  end
end
