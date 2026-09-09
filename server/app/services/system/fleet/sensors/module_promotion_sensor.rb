# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects a promotion the ladder is READY for: a pinned environment whose
      # rung below serves a version the plane itself does not, where
      # PromotionCriteria are met (enough healthy instances on that lower rung
      # have run this exact digest for the dwell time). Emits
      # `system.module_promotion_ready`, which the DecisionEngine binds to
      # NodeModule#promote_in_environment! through
      # FleetAutonomyService's `system.module_promote_to_live` gate.
      #
      # WHAT CHANGED IN INCREMENT 4b. This sensor used to scan for
      # NodeModuleVersion rows sitting at `promotion_state: "staging"` — a rung
      # no automated path ever wrote, so the scope rested permanently empty and
      # PromotionCriteria was never once evaluated automatically. The ladder it
      # watched was decorative and is gone. The scope is now derived from state
      # the platform actually maintains: the pins
      # (System::ModuleEnvironmentPin) and Ai::Environment#ladder_predecessor.
      # It is populated the moment a pinned plane falls behind the rung below
      # it, which happens on every ordinary promotion into that lower rung.
      #
      # An eligible verdict is a RECOMMENDATION, not an actuation: the plane's
      # own gate still decides (prod is seeded supervised, so it parks for a
      # person). Criteria that cannot pass on a small fleet make this sensor
      # quiet rather than wrong — the manual verbs remain the escape hatch, and
      # System::Fleet::ManualPromotionAdvisory records each override they take
      # as a system.module_promotion_criteria_override FleetEvent, which is an
      # audit record and NOT a signal this or any sensor emits.
      class ModulePromotionSensor < BaseSensor
        def sense
          pinned_environments.flat_map { |environment| candidates_for(environment) }
        end

        private

        # Pinned planes that HAVE a rung below them. A pinned plane with no
        # lower rung takes what is published; there is no promotion to be ready
        # for, and no lower plane whose instances could evidence one.
        def pinned_environments
          ::Ai::Environment.where(account_id: account.id, auto_promote_on_publish: false)
                           .order(:tier, :position)
                           .filter_map { |env| [ env, env.ladder_predecessor ] if env.ladder_predecessor }
        end

        def candidates_for((environment, predecessor))
          ::System::NodeModule.where(account_id: account.id)
                              .includes(:current_version, environment_pins: :node_module_version)
                              .find_each.filter_map do |node_module|
            candidate = node_module.served_version_for(predecessor)
            next if candidate.nil?
            next if node_module.served_version_for(environment)&.id == candidate.id

            criteria = ::System::Fleet::PromotionCriteria.evaluate(version: candidate, environment: environment)
            next unless criteria[:eligible]

            promotion_ready_signal(node_module, environment, predecessor, candidate, criteria)
          end
        end

        def promotion_ready_signal(node_module, environment, predecessor, candidate, criteria)
          signal(
            kind: "system.module_promotion_ready",
            severity: :medium,
            payload: {
              module_id: node_module.id,
              module_name: node_module.name,
              module_version_id: candidate.id,
              version_number: candidate.version_number,
              environment_id: environment.id,
              environment: environment.slug,
              evidence_environment: predecessor.slug,
              running_count: criteria[:running_count],
              required_count: criteria[:required_count],
              dwell_time_minutes: criteria[:dwell_time_minutes]
            },
            # Keyed on the (plane, version) pair: a different candidate for the
            # same plane is a new fact and must alarm again.
            fingerprint: "promotion_ready:#{environment.id}:#{candidate.id}"
          )
        end
      end
    end
  end
end
