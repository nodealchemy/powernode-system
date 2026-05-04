# frozen_string_literal: true

# Operator-facing CRUD for Sdwan::PortMapping. Hub peers publish
# overlay services to v4-only clients via DNAT entries declared here.
# The compiler (Sdwan::NatCompiler) renders these to nft rules in
# the per-network sdwan_nat_<8> chain on the next agent reconcile.
#
# Slice 7b of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class PortMappingsController < ::Api::V1::System::BaseController
          before_action :set_account
          before_action :set_network
          before_action :set_mapping, only: %i[show update destroy]

          def index
            require_permission("sdwan.port_mappings.read")
            scope = @network.port_mappings
            scope = scope.where(sdwan_peer_id: params[:hub_peer_id]) if params[:hub_peer_id].present?
            scope = scope.where(enabled: ActiveModel::Type::Boolean.new.cast(params[:enabled])) if params.key?(:enabled)
            mappings = scope.order(:listen_port, :protocol)
            render_success(port_mappings: mappings.map { |m| serialize(m) }, count: mappings.size)
          end

          def show
            require_permission("sdwan.port_mappings.read")
            render_success(port_mapping: serialize_full(@mapping))
          end

          def create
            require_permission("sdwan.port_mappings.manage")
            mapping = @network.port_mappings.new(mapping_params.merge(account_id: @account.id))
            if mapping.save
              render_success({ port_mapping: serialize_full(mapping) }, status: :created)
            else
              render_validation_error(mapping)
            end
          end

          def update
            require_permission("sdwan.port_mappings.manage")
            if @mapping.update(mapping_params)
              render_success(port_mapping: serialize_full(@mapping))
            else
              render_validation_error(@mapping)
            end
          end

          def destroy
            require_permission("sdwan.port_mappings.manage")
            @mapping.destroy!
            render_success(deleted: true, id: @mapping.id)
          end

          private

          def set_network
            @network = ::Sdwan::Network.where(account_id: @account.id).find(params[:network_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Network")
          end

          def set_mapping
            @mapping = @network.port_mappings.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Port Mapping")
          end

          def mapping_params
            params.require(:port_mapping).permit(
              :name, :description, :sdwan_peer_id, :target_peer_id, :target_virtual_ip_id,
              :listen_port, :target_port, :protocol, :enabled, metadata: {}
            )
          end

          def serialize(m)
            {
              id: m.id,
              network_id: m.sdwan_network_id,
              hub_peer_id: m.sdwan_peer_id,
              target_peer_id: m.target_peer_id,
              target_virtual_ip_id: m.target_virtual_ip_id,
              name: m.name,
              listen_port: m.listen_port,
              target_port: m.target_port,
              effective_target_port: m.effective_target_port,
              protocol: m.protocol,
              enabled: m.enabled,
              last_compiled_at: m.last_compiled_at&.iso8601,
              created_at: m.created_at&.iso8601
            }
          end

          def serialize_full(m)
            serialize(m).merge(
              description: m.description,
              metadata: m.metadata,
              resolved_target_address: m.resolved_target_address
            )
          end
        end
      end
    end
  end
end
