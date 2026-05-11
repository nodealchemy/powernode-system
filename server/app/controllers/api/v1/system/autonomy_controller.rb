# frozen_string_literal: true

module Api
  module V1
    module System
      # Configures per-action intervention policies + approval chain assignment
      # for the System extension's autonomy framework. Powered by
      # `::System::AutonomyActions` concern (extension-local) which contains
      # the bulk of the logic so it can be reused if other system controllers
      # need it.
      class AutonomyController < BaseController
        include ::System::AutonomyActions

        before_action :require_view_permission, only: [:show]
        before_action :require_manage_permission, only: [:update]

        private

        def require_view_permission
          require_permission("system.infra_tasks.read")
        end

        def require_manage_permission
          require_permission("system.infra_tasks.control")
        end
      end
    end
  end
end
