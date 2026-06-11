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

        # F3-11(a): every signal carries its producing sensor ("_sensor") so
        # the RemediationValidator can require the OWNING sensor to have run
        # before scoring a fingerprint's absence as "effective" — a sensor
        # that crashed mid-tick removes its signals from the sense pass, and
        # absence-without-provenance falsely validated every pending outcome.
        def signal(kind:, severity:, payload:, fingerprint:)
          ::System::Fleet::Signal.new(
            kind: kind,
            severity: severity,
            payload: (payload || {}).merge("_sensor" => self.class.name.demodulize),
            fingerprint: fingerprint
          )
        end
      end
    end
  end
end
