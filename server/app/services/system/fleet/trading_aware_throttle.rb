# frozen_string_literal: true

module System
  module Fleet
    # Cross-domain throttle: when trading-pressure signals are present in
    # the stigmergic bus, the fleet defers non-critical actions to free
    # up cycles for trading-side work. Inverse of TradingPressureSensor —
    # this is the *consume* side, the sensor is the *observe* side.
    #
    # Used by FleetAutonomyService.gate_action! for actions tagged as
    # "non-critical" (instance_reboot, module_assign, capacity_resize) —
    # these get delayed when trading pressure is high. Critical actions
    # (cert_revoke, instance_terminate, module_promote_to_live) bypass
    # the throttle since they represent operator-or-AI-driven safety
    # responses where delay is worse than throttling.
    #
    # Reference: Golden Eclipse plan stigmergic coordination — bidirectional
    # fleet ↔ trading pressure exchange.
    class TradingAwareThrottle
      NON_CRITICAL_ACTIONS = %w[
        system.module_assign
        system.instance_reboot
        system.capacity_resize
        system.cert_rotate
      ].freeze

      THROTTLE_STRENGTH_THRESHOLD = 1.0

      # Returns { throttled: bool, reason: string, defer_seconds: int }.
      # Caller decides what to do with the deferral hint.
      def self.evaluate(account:, action_category:)
        new.evaluate(account: account, action_category: action_category)
      end

      def evaluate(account:, action_category:)
        return { throttled: false, reason: "critical_action_bypass" } unless NON_CRITICAL_ACTIONS.include?(action_category)
        return { throttled: false, reason: "stigmergic_unavailable" } unless defined?(::Ai::Coordination::StigmergicSignalService)

        service = ::Ai::Coordination::StigmergicSignalService.new(account: account)
        signals = service.perceive(
          agent: nil,
          signal_types: %w[trading.high_load trading.market_pressure],
          limit: 20
        )
        aggregate = Array(signals).sum { |s| s.strength.to_f }

        if aggregate >= THROTTLE_STRENGTH_THRESHOLD
          # Defer hint scales with pressure — modest delay so the fleet
          # eventually catches up, longer delay when trading is very busy.
          defer_seconds = [ (aggregate * 60).to_i, 600 ].min
          {
            throttled: true,
            reason: "trading_pressure_aggregate=#{aggregate.round(2)}",
            defer_seconds: defer_seconds,
            signal_count: signals.size
          }
        else
          { throttled: false, reason: "below_threshold", aggregate: aggregate.round(2) }
        end
      rescue StandardError => e
        Rails.logger.warn("[TradingAwareThrottle] #{e.class}: #{e.message}")
        { throttled: false, reason: "service_error" }
      end
    end
  end
end
