# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects NodeModuleVersion rows in `staging` that meet the
      # PromotionCriteria (sufficient instances running the version for a
      # minimum dwell time). Emits `system.module_promotion_ready` signals,
      # which the DecisionEngine binds to ModulePromotionService.
      class ModulePromotionSensor < BaseSensor
        def sense
          ::System::NodeModuleVersion
            .joins(node_module: :account)
            .where(accounts: { id: account.id })
            .where(promotion_state: "staging")
            .find_each.filter_map do |version|
            criteria = ::System::Fleet::PromotionCriteria.evaluate(version: version)
            next unless criteria[:eligible]

            signal(
              kind: "system.module_promotion_ready",
              severity: :medium,
              payload: {
                module_version_id: version.id,
                module_id: version.node_module_id,
                version_number: version.version_number,
                running_count: criteria[:running_count],
                required_count: criteria[:required_count],
                dwell_time_minutes: criteria[:dwell_time_minutes]
              },
              fingerprint: "promotion_ready:#{version.id}"
            )
          end
        end
      end
    end
  end
end
