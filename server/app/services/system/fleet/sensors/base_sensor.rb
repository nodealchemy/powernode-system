# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Common shape for fleet sensors. Each sensor's #sense returns an
      # array of signal hashes:
      #   {
      #     kind: "system.<topic>",  # match action_category for routing
      #     severity: :low | :medium | :high | :critical,
      #     payload: { ... },        # carried into ApprovalRequest.request_data
      #     fingerprint: "stable-key" # used by DecisionEngine to dedup repeats
      #   }
      #
      # Sensors are pure read-side: they may not mutate the database. The
      # DecisionEngine is responsible for routing the signal to a skill and
      # gating it via FleetAutonomyService.
      class BaseSensor
        def initialize(account:)
          @account = account
        end

        def sense
          raise NotImplementedError
        end

        protected

        attr_reader :account

        def signal(kind:, severity:, payload:, fingerprint:)
          ::System::Fleet::Signal.new(
            kind: kind,
            severity: severity,
            payload: payload,
            fingerprint: fingerprint
          )
        end
      end
    end
  end
end
