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

      # What #check_and_consume! WOULD answer right now, with no write.
      Headroom = Struct.new(:budget, :used, :remaining, :exhausted, :reason, keyword_init: true)

      def self.check_and_consume!(module_id:)
        new.check_and_consume!(module_id: module_id)
      end

      def self.headroom(module_id:)
        new.headroom(module_id: module_id)
      end

      def check_and_consume!(module_id:)
        return Result.new(allowed: true, remaining: nil, reason: "no_module_id") if module_id.blank?

        mod = ::System::NodeModule.find_by(id: module_id)
        return Result.new(allowed: true, remaining: nil, reason: "module_not_found") unless mod

        budget = mod.consent_budget_per_day
        return Result.new(allowed: true, remaining: nil, reason: "no_budget_set") if budget.nil? || budget <= 0

        # Reset window if expired.
        if window_expired?(mod)
          mod.update!(consent_budget_window_start_at: Time.current, consent_budget_used_count: 0)
        end

        if mod.consent_budget_used_count >= budget
          return Result.new(
            allowed: false,
            remaining: 0,
            reason: exhausted_reason(mod.consent_budget_used_count, budget)
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

      # READ-ONLY twin of #check_and_consume! (campaign 01a08c9b B4): the
      # remediation lane's describe reports headroom with it, and a describe
      # must never move the budget. An expired window reads as empty, exactly
      # as #check_and_consume! would reset it, but is NOT reset here. Same
      # fail-open posture: a crash reports "not exhausted".
      def headroom(module_id:)
        return open_headroom("no_module_id") if module_id.blank?

        mod = ::System::NodeModule.find_by(id: module_id)
        return open_headroom("module_not_found") unless mod

        budget = mod.consent_budget_per_day
        return open_headroom("no_budget_set") if budget.nil? || budget <= 0

        used = window_expired?(mod) ? 0 : mod.consent_budget_used_count.to_i
        if used >= budget
          return Headroom.new(budget: budget, used: used, remaining: 0, exhausted: true,
                              reason: exhausted_reason(used, budget))
        end

        Headroom.new(budget: budget, used: used, remaining: budget - used, exhausted: false, reason: "ok")
      rescue StandardError => e
        Rails.logger.warn("[ConsentBudgetService] headroom #{e.class}: #{e.message}")
        open_headroom("service_error")
      end

      private

      def window_expired?(mod)
        mod.consent_budget_window_start_at.nil? || mod.consent_budget_window_start_at < WINDOW_DURATION.ago
      end

      def exhausted_reason(used, budget)
        "budget_exhausted: #{used}/#{budget} used in current window"
      end

      def open_headroom(reason)
        Headroom.new(budget: nil, used: nil, remaining: nil, exhausted: false, reason: reason)
      end
    end
  end
end
