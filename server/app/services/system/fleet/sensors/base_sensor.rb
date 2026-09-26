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
      # Sensors are read-side: they must not actuate or write anything a
      # skill would (the DecisionEngine routes the signal to a skill and gates
      # it via FleetAutonomyService). The one sanctioned write is a sensor
      # persisting the SAMPLE it just took so a consumer can read it later —
      # ReplicaLagSensor writes cluster_pg.replication_lag_bytes for
      # PromoteReplicaExecutor's data-loss gate (IMP-5b38cd356010); it never
      # manufactures a reading it did not take.
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

        # ── The SECOND tunable store ─────────────────────────────────────
        #
        # .default_thresholds above is the SensorConfig ladder: one per-account
        # row keyed by sensor_key, written by system_update_sensor_config.
        # EIGHT sensors resolve their windows a different way — Account#settings,
        # then a deployment-wide SiteSetting, then a constant — and declare that
        # ladder with a pair of prefix constants plus one DEFAULT_<KEY> constant
        # per tunable value.
        #
        # Nothing read those, so system_get_sensor_config listed five sensors
        # while thirteen were tunable, and an operator looking for
        # `sdwan_service_health_flow_window_seconds` concluded it was not
        # configurable. That is the same defect IMP-ca485128072e was opened for
        # (a documented key nothing implemented), one store over.
        #
        # DERIVED, NOT RESTATED. The keys come from the sensor's own DEFAULT_*
        # constants (DEFAULT_FLOW_WINDOW_SECONDS -> "flow_window_seconds"), so a
        # new tunable reaches the verb the moment the constant exists and no
        # list has to be edited. What keeps that convention from drifting
        # silently is the spec: it asserts this derived key set equals the
        # literal suffixes the sensor's source passes to its own resolver, so a
        # sensor that names a key one way and its constant another fails loudly
        # instead of under-reporting.
        #
        # A sensor with no ACCOUNT_SETTING_PREFIX is not on this ladder and
        # returns {} — the same "declares nothing, tunes nothing" rule the
        # thresholds seam uses.
        def self.account_ladder_settings
          return {} unless const_defined?(:ACCOUNT_SETTING_PREFIX, false)

          account_prefix = const_get(:ACCOUNT_SETTING_PREFIX)
          site_prefix    = const_defined?(:SETTING_PREFIX, false) ? const_get(:SETTING_PREFIX) : nil

          constants(false).grep(/\ADEFAULT_[A-Z0-9_]+\z/).sort.to_h do |const|
            key = const.to_s.delete_prefix("DEFAULT_").downcase
            [
              key,
              {
                "default" => const_get(const),
                "account_setting" => "#{account_prefix}_#{key}",
                "site_setting" => site_prefix ? "#{site_prefix}.#{key}" : nil
              }.compact
            ]
          end
        end

        # Bounds a sensor clamps a configured value into, keyed the same way.
        # Declared rather than applied privately so the value this seam REPORTS
        # as effective is the value the sensor USES — a read verb that reports
        # 40 while the sensor clamps to 20 is a lie with a plausible source.
        def self.account_ladder_bounds
          const_defined?(:ACCOUNT_LADDER_BOUNDS, false) ? const_get(:ACCOUNT_LADDER_BOUNDS) : {}
        end

        # The ladder resolved for one account: Account#settings, then the
        # deployment-wide SiteSetting, then the constant. Non-positive is
        # treated as UNSET rather than as zero — a zero window would mark
        # everything stale, which is exactly what an operator clearing a field
        # does not mean.
        def self.resolved_account_ladder(account:)
          account_ladder_settings.to_h do |key, spec|
            [ key, resolve_ladder_value(key, spec, account) ]
          end
        end

        def self.resolve_ladder_value(key, spec, account)
          raw = account&.settings&.dig(spec["account_setting"]).presence
          raw ||= ::SiteSetting.get(spec["site_setting"]) if spec["site_setting"] && defined?(::SiteSetting)
          value = raw.to_i
          return spec["default"] unless value.positive?

          bounds = account_ladder_bounds[key]
          bounds ? value.clamp(bounds.min, bounds.max) : value
        rescue StandardError => e
          Rails.logger.warn("[#{name}] account-ladder #{key} fell back to its default: #{e.class}: #{e.message}")
          spec["default"]
        end
        private_class_method :resolve_ladder_value

        # True when an operator can tune anything about this sensor at all —
        # through either store. The MCP catalog is derived from this.
        def self.configurable?
          threshold_writable? || account_ladder_settings.present?
        end

        # True when system_update_sensor_config can WRITE this sensor's
        # thresholds — i.e. they live in the SensorConfig store it owns.
        #
        # One predicate, two call sites, on purpose: the read verb's
        # `writable` flag and the write verb's refusal used to be the same
        # expression written twice, which is a pair that agrees until someone
        # edits one of them. The listing predicate got a home in
        # .configurable?; writability gets the same.
        def self.threshold_writable?
          default_thresholds.present?
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

        # Counts about the LAST #sense that are not signals, e.g. candidates a
        # sensor skipped on purpose. FleetAutonomyService puts every non-empty
        # hash on fleet.tick_complete under sensor_diagnostics, keyed by
        # sensor_key. Never a signal: the decision engine acts on signals, and
        # a skip re-signalled is the noise the skip removed.
        def diagnostics
          {}
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
