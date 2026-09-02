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
        # IMP-ca485128072e (APO-2e) — the ONE threshold resolution seam.
        #
        # A sensor declares its tunable keys and their constant defaults by
        # overriding .default_thresholds; everything else — the DB lookup, the
        # validation, the fallback — happens here, once, for every sensor. The
        # alternative (each sensor reading its own override) is how the ENV
        # overrides on InstanceUnrecoverableSensor came to exist: three reads
        # in one file, no validation, and no way for an operator to discover
        # what was tunable.
        #
        # A sensor that overrides nothing is not configurable, and
        # #resolved_threshold raises for every key — which is what makes a typo
        # in an MCP call an error rather than a silently ignored tuning.
        def self.default_thresholds
          {}
        end

        # The name the docs, the MCP verbs and the SensorConfig row all use.
        # Derived, not restated: InstanceStatusSensor -> "instance_status".
        def self.sensor_key
          name.demodulize.underscore.delete_suffix("_sensor")
        end

        # Effective value for one declared key, for one account.
        #
        # FAILS TO THE CONSTANT, never to nil and never by raising, for any
        # stored value that is not a positive integer — a sensor tick runs
        # unattended every 60s, and a bad row must not stop the whole
        # perception pass or silently disable a detector (`max_per_tick: 0`
        # reads exactly like "never look at anything"). An UNDECLARED key does
        # raise: that is a caller error, not fleet data, and the MCP write verb
        # rejects it before it can ever be stored.
        def self.resolved_threshold(key, account:)
          name_key = key.to_s
          fallback = default_thresholds.fetch(name_key) do
            raise KeyError, "#{self.name} declares no threshold #{name_key.inspect} " \
                            "(declared: #{default_thresholds.keys.sort.inspect})"
          end

          stored = ::System::Fleet::SensorConfig.config_for(account: account, sensor: sensor_key)[name_key]
          ::System::Fleet::SensorConfig.coerce_threshold(stored) || fallback
        rescue KeyError
          raise
        rescue StandardError => e
          Rails.logger.warn("[#{name}] threshold #{key} fell back to its default: #{e.class}: #{e.message}")
          default_thresholds[key.to_s]
        end

        # Every declared key resolved at once — what the MCP read verb reports
        # and what an instance memoizes for one sense pass.
        #
        # ONE row read for the whole set, not one per key: .resolved_threshold
        # is the single-key entry point and re-reads, which is right for a
        # caller asking one question and wrong for a caller asking all of them.
        def self.resolved_thresholds(account:)
          stored = ::System::Fleet::SensorConfig.config_for(account: account, sensor: sensor_key)
          default_thresholds.to_h do |key, fallback|
            [ key, ::System::Fleet::SensorConfig.coerce_threshold(stored[key]) || fallback ]
          end
        rescue StandardError => e
          Rails.logger.warn("[#{name}] thresholds fell back to defaults: #{e.class}: #{e.message}")
          default_thresholds
        end

        def initialize(account:)
          @account = account
        end

        def sense
          raise NotImplementedError
        end

        protected

        attr_reader :account

        # Memoized for the life of ONE sensor instance, which is one tick: a
        # sense pass must not straddle a mid-tick config change and emit
        # signals measured against two different thresholds.
        def threshold(key)
          @resolved_thresholds ||= self.class.resolved_thresholds(account: account)
          @resolved_thresholds.fetch(key.to_s) do
            raise KeyError, "#{self.class.name} declares no threshold #{key.inspect}"
          end
        end

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
