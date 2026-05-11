# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Module version upload endpoint for the agent's commit CLI.
        # Accepts a base64-encoded tar.zst payload + sha256 + changelog,
        # runs defense-in-depth verification server-side, and creates
        # a NodeModuleVersion at promotion_state: "built".
        #
        # The platform's ModulePromotionService handles the canary →
        # staging → blessed → live progression; agent commits land at
        # "built" and require explicit operator promotion.
        #
        # Phase 4 of the agent stub implementation plan. Stub #13
        # (commit CLI) consumes this endpoint via --push.
        class ModuleVersionsController < BaseController
          before_action :set_module

          # POST /api/v1/system/node_api/modules/:id/versions
          # Body: { tar_b64, sha256, size_bytes, changelog }
          # Returns: { version: { id, version_number, promotion_state } }
          def create
            result = ::System::AgentModuleCommitService.call(
              node_module: @module,
              tar_b64: params.require(:tar_b64),
              sha256: params.require(:sha256),
              size_bytes: params[:size_bytes].to_i,
              changelog: params[:changelog],
              committer_instance: current_instance
            )

            unless result.success?
              Rails.logger.warn("[ModuleVersionsController] commit failed: #{result.error}")
              return render_error(result.error, :unprocessable_entity)
            end

            render_success(
              version: {
                id: result.version.id,
                version_number: result.version.version_number,
                promotion_state: result.version.promotion_state,
                data_file_name: result.version.data_file_name
              }
            )
          end

          private

          def set_module
            @module = node_modules.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("NodeModule")
          end

          def node_modules
            current_node.node_modules
          end
        end
      end
    end
  end
end
