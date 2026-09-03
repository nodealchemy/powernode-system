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

        # Which target states the criteria gate is decided ONCE, in
        # PromotionCriteria::GATED_TARGET_STATES (today: `blessed`, the rung
        # that claims the fleet has run this and lived). Promotions to retired
        # need no criteria — those are operator-driven decommissions — and
        # neither does explicit blessed → live, since blessed already implies
        # the criteria once passed. The manual promote paths consult the same
        # set through ManualPromotionAdvisory and WARN where this lane refuses
        # (IMP-bdb650b82c65 replaced a private `== "blessed"` literal here).
        if PromotionCriteria.gates?(target_state) && !criteria[:eligible]
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
