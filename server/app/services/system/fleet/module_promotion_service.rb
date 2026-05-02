# frozen_string_literal: true

module System
  module Fleet
    # Advances a NodeModuleVersion through its promotion lifecycle when
    # PromotionCriteria are met. Used by DecisionEngine when a
    # `system.module_promotion_ready` signal arrives.
    #
    # The promotion itself is gated by FleetAutonomyService (default policy
    # for system.module_promote_to_live = require_approval, 4h TTL). This
    # service is the *executor* — it's only reached after the gate decision
    # is :proceed. For staging→blessed (intermediate), the policy is more
    # permissive (default: notify_and_proceed) and this service runs inline.
    class ModulePromotionService
      Result = Struct.new(:ok?, :data, :error, keyword_init: true)

      def self.promote!(version:, target_state:)
        new.promote!(version: version, target_state: target_state)
      end

      def promote!(version:, target_state:)
        criteria = PromotionCriteria.evaluate(version: version)

        # Promotions to retired don't need PromotionCriteria — those are
        # operator-driven decommissions. Same for explicit blessed → live
        # since blessed already implies criteria once passed.
        if target_state == "blessed" && !criteria[:eligible]
          return Result.new(ok?: false, error: "not eligible: #{criteria[:reason]}", data: criteria)
        end

        version.promote_to!(target_state)
        Result.new(ok?: true, data: { version_id: version.id,
                                       promoted_to: target_state,
                                       criteria: criteria })
      rescue ::System::NodeModuleVersion::InvalidTransition, ArgumentError => e
        Result.new(ok?: false, error: e.message)
      end
    end
  end
end
