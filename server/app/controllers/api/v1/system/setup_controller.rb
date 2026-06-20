# frozen_string_literal: true

module Api
  module V1
    module System
      # Setup-wizard step endpoint contributed by the system extension via
      # extension.json `setup_steps`. The core setup wizard renders the step from
      # the manifest and POSTs its payload here; per-extension completion is stamped
      # by core (POST /api/v1/setup/extensions/system/configured).
      class SetupController < BaseController
        # POST /api/v1/system/setup/defaults
        def defaults
          return render_forbidden unless current_user&.has_permission?("system.admin")

          region = params[:default_region].to_s.strip
          AdminSetting.set("system.default_region", region) if region.present?
          render_success(saved: true)
        end
      end
    end
  end
end
