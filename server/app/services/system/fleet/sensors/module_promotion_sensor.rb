# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects NodeModuleVersion rows in `staging` that meet the
      # PromotionCriteria (sufficient instances running the version for a
      # minimum dwell time). Emits `system.module_promotion_ready` signals,
      # which the DecisionEngine binds to ModulePromotionService.
      #
      # This scope rests EMPTY on the live control plane, and deliberately so.
      # Per docs/design/promotion-ladder-semantics.md (IMP-c7d618b0b72f),
      # `staging` means "a build was nominated for evidence-based blessing" —
      # no automated path writes it, and none may be added to give this sensor
      # input. Empty is the correct resting state for THIS rung. The only
      # producers are the two promote verbs (POST
      # /node_module_versions/:id/promote and system_promote_module_version),
      # and a caller that walks straight through to `blessed` leaves nothing
      # here.
      #
      # Kept rather than deleted, but be precise about why: those same two
      # verbs can also write `blessed` directly, so this is NOT the only way a
      # version becomes blessed. It is the only AUTOMATED, criteria-evidenced
      # way (via DecisionEngine#apply_module_promotion ->
      # ModulePromotionService, target "blessed"); the sole other automated
      # producer, PackageBuildWebhookService, blesses only auto_generated
      # transitive deps. Deleting this sensor would leave `blessed` reachable
      # by hand alone.
      #
      # PromotionCriteria has never evaluated production data, and on a 1-2
      # instance fleet its defaults probably cannot pass at all. Run the
      # shadow-mode pass in that note's section 4.1 before making this lane
      # load-bearing.
      class ModulePromotionSensor < BaseSensor
        def sense
          ::System::NodeModuleVersion
            .joins(node_module: :account)
            .includes(node_module: :account)
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
