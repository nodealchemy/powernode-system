# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # REST shim over the storage volume MCP actions. Lets the
        # deployment wizard create + list volumes without going through
        # the MCP dispatch boundary. The MCP layer (SystemFleetTool)
        # remains the authoritative implementation.
        #
        # Plan reference: E6 (in-wizard volume creation).
        class VolumesController < ApplicationController
          before_action :authenticate_request

          def index
            return forbidden unless current_user&.has_permission?("system.volumes.read")
            result = tool.execute(params: index_params)
            unwrap(result)
          end

          def create
            return forbidden unless current_user&.has_permission?("system.volumes.create")
            result = tool.execute(params: create_params)
            unwrap(result, success_status: :created)
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def tool
            @tool ||= ::Ai::Tools::SystemFleetTool.new(account: current_account, user: current_user)
          end

          def index_params
            permitted = params.permit(:status, :transport, :node_instance_id, :unattached_only).to_h.symbolize_keys
            permitted.merge(action: "system_list_volumes")
          end

          def create_params
            permitted = params.permit(
              :name, :size_gb, :description,
              :transport, :nfs_server, :nfs_export_path, :nfs_version,
              :volume_type_id
            ).to_h.symbolize_keys
            permitted.merge(action: "system_create_volume")
          end

          def unwrap(result, success_status: :ok)
            if result[:success]
              render_success(result[:data], status: success_status)
            else
              render_error(result[:error].to_s, status: :unprocessable_entity)
            end
          end
        end
      end
    end
  end
end
