# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Cross-domain sensor: reads stigmergic signals emitted by trading
      # subsystems (trading.high_load, trading.market_pressure, etc.) and
      # surfaces them as fleet-domain signals so DecisionEngine can adjust
      # severity weighting + the decision_engine can defer non-critical
      # actions when trading is hot.
      #
      # The platform's existing `Ai::Coordination::StigmergicSignalService`
      # is the cross-domain bus. Both trading and fleet emit + perceive
      # against it.
      #
      # Reference: Golden Eclipse plan + stigmergic coordination architecture
      # — fleet ↔ trading swarm intelligence layer.
      class TradingPressureSensor < BaseSensor
        TRADING_SIGNAL_TYPES = %w[
          trading.high_load
          trading.market_pressure
          trading.session_concurrency_limit
          trading.live_capital_warning
        ].freeze

        STRENGTH_THRESHOLD = 0.5

        def sense
          return [] unless defined?(::Ai::Coordination::StigmergicSignalService)

          service = ::Ai::Coordination::StigmergicSignalService.new(account: account)
          signals = service.perceive(
            agent: nil,                     # global perception, not bound to one agent
            signal_types: TRADING_SIGNAL_TYPES,
            limit: 50
          )

          relevant = Array(signals).select { |s| s.strength.to_f >= STRENGTH_THRESHOLD }
          return [] if relevant.empty?

          # Aggregate into a single fleet-side signal so DecisionEngine
          # doesn't dispatch one decision per trading signal — they collectively
          # mean "trading is busy; throttle non-critical fleet actions".
          aggregate_strength = relevant.sum { |s| s.strength.to_f }
          severity = case aggregate_strength
                     when 0..1.0 then :medium
                     when 1.0..3.0 then :high
                     else :critical
                     end

          [
            signal(
              kind: "system.trading_pressure_observed",
              severity: severity,
              payload: {
                aggregate_strength: aggregate_strength.round(3),
                source_signal_types: relevant.map(&:signal_type).uniq,
                source_signal_count: relevant.size,
                strongest: relevant.max_by(&:strength).then do |s|
                  { type: s.signal_type, key: s.signal_key, strength: s.strength.to_f.round(3) }
                end
              },
              fingerprint: "trading_pressure:#{Time.current.to_i / 60}" # 1-minute bucket
            )
          ]
        rescue StandardError => e
          Rails.logger.warn("[TradingPressureSensor] perceive failed: #{e.message}")
          []
        end
      end
    end
  end
end
