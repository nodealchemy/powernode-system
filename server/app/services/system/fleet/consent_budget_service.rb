# frozen_string_literal: true

module System
  module Fleet
    # Per-module consent budget enforcement. Applied as a hook in
    # FleetAutonomyService#gate_action! so the operator's "no more than
    # N autonomous decisions per day for this module" ceiling is honored
    # independently of any InterventionPolicy decision.
    #
    # The budget is reset every 24 hours from `consent_budget_window_start_at`.
    # When budget is nil, no enforcement is applied (back-compat for modules
    # without an operator-set ceiling).
    #
    # Reference: Golden Eclipse plan creative — module consent budget.
    class ConsentBudgetService
      WINDOW_DURATION = 24.hours

      Result = Struct.new(:allowed, :remaining, :reason, keyword_init: true)

      def self.check_and_consume!(module_id:)
        new.check_and_consume!(module_id: module_id)
      end

      def check_and_consume!(module_id:)
        return Result.new(allowed: true, remaining: nil, reason: "no_module_id") if module_id.blank?

        mod = ::System::NodeModule.find_by(id: module_id)
        return Result.new(allowed: true, remaining: nil, reason: "module_not_found") unless mod

        budget = mod.consent_budget_per_day
        return Result.new(allowed: true, remaining: nil, reason: "no_budget_set") if budget.nil? || budget <= 0

        # Reset window if expired.
        if mod.consent_budget_window_start_at.nil? || mod.consent_budget_window_start_at < WINDOW_DURATION.ago
          mod.update!(consent_budget_window_start_at: Time.current, consent_budget_used_count: 0)
        end

        if mod.consent_budget_used_count >= budget
          return Result.new(
            allowed: false,
            remaining: 0,
            reason: "budget_exhausted: #{mod.consent_budget_used_count}/#{budget} used in current window"
          )
        end

        # Atomic increment to handle concurrent ticks.
        ::System::NodeModule.where(id: mod.id).update_all("consent_budget_used_count = consent_budget_used_count + 1")
        Result.new(allowed: true,
                   remaining: budget - mod.consent_budget_used_count - 1,
                   reason: "ok")
      rescue StandardError => e
        Rails.logger.warn("[ConsentBudgetService] #{e.class}: #{e.message}")
        # Fail-open: a service crash shouldn't block autonomy. Operator
        # can review fleet events to spot crashes.
        Result.new(allowed: true, remaining: nil, reason: "service_error")
      end
    end
  end
end
