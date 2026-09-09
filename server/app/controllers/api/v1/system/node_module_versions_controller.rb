# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing endpoints on NodeModuleVersion. Exposes the promotion
      # step (POST :id/promote) so an operator can move a PINNED environment
      # onto this version without rails console access.
      #
      # Environment campaign, increment 4b: the decorative
      # built → staging → blessed → live ladder this endpoint used to advance
      # is gone. A promotion now names the environment it promotes INTO and
      # writes that plane's pin (System::ModuleEnvironmentPin), which is what
      # its nodes converge on. The rules live in
      # System::NodeModule#ladder_refusal: one pinned rung at a time, never
      # into a following plane, never an unmountable artifact.
      #
      # This endpoint is the OPERATOR path and is not gated by the autonomy
      # policy — a signed-in human with system.modules.update decides. The
      # agent-facing twin (system_promote_module_version) carries the gate and
      # parks in a protected plane. Both consult PromotionCriteria through
      # ManualPromotionAdvisory and WARN rather than refuse (operator ruling
      # D17, 2026-09-02).
      class NodeModuleVersionsController < BaseController
        before_action :set_node_module_version, only: [ :promote ]

        # POST /api/v1/system/node_module_versions/:id/promote
        # Body: { environment: "<slug or id>" }
        def promote
          require_permission("system.modules.update")

          slug = params[:environment].to_s
          return render_error("environment is required", 400) if slug.blank?

          environment = ::Ai::Environment.find_for_account(current_account.id, slug)
          return render_error("environment '#{slug}' not found in this account", 404) if environment.nil?

          node_module = @version.node_module
          if (refusal = node_module.ladder_refusal(environment: environment, version: @version))
            return render_error(refusal, 422)
          end

          # Consult PromotionCriteria and WARN; never refuse. The escape hatch
          # keeps its authority (small fleets, incidents, rollbacks); what it
          # does not do is promote past the evidence bar in silence. The verdict
          # is computed BEFORE the pin moves and recorded only once it landed.
          advisory = ::System::Fleet::ManualPromotionAdvisory.evaluate(
            version: @version, environment: environment
          )

          pin = node_module.promote_in_environment!(
            environment: environment, version: @version, actor: current_user
          )

          render_success(
            {
              node_module_version: serialize_version(@version.reload),
              environment: environment.slug,
              promoted_at: pin.promoted_at&.iso8601
            }.merge(
              advisory.record!(
                source: ::System::Fleet::ManualPromotionAdvisory::REST_SOURCE,
                actor_id: current_user&.id,
                # This endpoint runs behind authenticate_user!, so a nil here
                # is a contract violation rather than a second principal kind;
                # it still records as "unknown" rather than vanishing.
                actor_type: current_user ? "user" : nil
              )
            )
          )
        rescue ::System::NodeModule::LadderError => e
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
            changelog: version.changelog,
            pinned_in: version.pinned_environments.pluck(:slug).sort,
            created_at: version.created_at
          }
        end
      end
    end
  end
end
