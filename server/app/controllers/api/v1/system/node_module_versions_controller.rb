# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing endpoints on NodeModuleVersion. Currently exposes
      # only the promotion transition (POST :id/promote) so operators can
      # advance a version through the lifecycle (built → staging → blessed
      # → live → retired) without rails console access.
      #
      # The state machine itself lives on System::NodeModuleVersion#promote_to!.
      # See PROMOTION_TRANSITIONS in that model for allowed transitions.
      class NodeModuleVersionsController < BaseController
        before_action :set_node_module_version, only: [ :promote ]

        # POST /api/v1/system/node_module_versions/:id/promote
        # Body: { target_state: "staging|blessed|live|retired|built" }
        def promote
          require_permission("system.modules.update")

          target_state = params[:target_state].to_s
          if target_state.blank?
            return render_error("target_state is required", 400)
          end

          @version.promote_to!(target_state)

          render_success(
            node_module_version: serialize_version(@version.reload)
          )
        rescue ArgumentError => e
          # Raised by promote_to! for unknown states.
          render_error(e.message, 422)
        rescue ::System::NodeModuleVersion::InvalidTransition => e
          render_error(e.message, 422)
        end

        private

        def set_node_module_version
          @version = ::System::NodeModuleVersion
            .joins(:node_module)
            .where(system_node_modules: { account_id: current_account.id })
            .find(params[:id])
        end

        def serialize_version(version)
          {
            id: version.id,
            node_module_id: version.node_module_id,
            version_number: version.version_number,
            promotion_state: version.promotion_state,
            changelog: version.changelog,
            staging_baked_at: version.staging_baked_at,
            blessed_at: version.blessed_at,
            live_at: version.live_at,
            retired_at: version.retired_at,
            created_at: version.created_at
          }
        end
      end
    end
  end
end
