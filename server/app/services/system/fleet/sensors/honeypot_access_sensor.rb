# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects access to honeypot canary modules within the lookback window.
      # Reads from the FleetEvent log (system.honeypot_triggered events that
      # CanaryModuleService.observe_access! emits) — this sensor's role is
      # to elevate them into the autonomy decision pipeline so the
      # operator's approval queue lights up immediately.
      #
      # Severity is always :critical — a canary access is by definition
      # an indicator of compromise.
      class HoneypotAccessSensor < BaseSensor
        LOOKBACK = 15.minutes

        def sense
          return [] unless defined?(::System::FleetEvent)

          ::System::FleetEvent
            .where(account: account, kind: "system.honeypot_triggered")
            .where("emitted_at >= ?", LOOKBACK.ago)
            .find_each.map do |event|
            signal(
              kind: "system.honeypot_access",
              severity: :critical,
              payload: {
                module_id: event.node_module_id,
                source: event.payload["source"],
                event_id: event.id,
                emitted_at: event.emitted_at.iso8601
              },
              fingerprint: "honeypot_access:#{event.id}"
            )
          end
        end
      end
    end
  end
end
