# frozen_string_literal: true

module System
  # Ingests the scalar runtime fields the heartbeat carries: mount_state,
  # load_average, memory_free_kb, uptime_seconds (the four the agent has
  # always sent and the server always discarded) plus cpu_pct, the on-node
  # percent-busy measurement APO-2a added.
  #
  # status_controller's own doc comment listed those four as accepted body
  # fields, and System::ProjectMetricsCollector named this exact source for
  # cpu_pct/memory_pct ("node agent heartbeat") — so the measurement landed
  # every 30 seconds and was thrown away while the metric reported
  # `unavailable` forever. cpu_pct closed the other half of that gap: the
  # source the collector named never actually carried a percentage until the
  # agent started measuring one.
  #
  # ABSENCE IS NOT A MEASUREMENT. `mount_state` and `uptime_seconds` are sent
  # unconditionally; `load_average` is Go `omitempty`; `memory_free_kb` and
  # `cpu_pct` are pointers that arrive as an explicit null when the node could
  # not measure them. A pre-feature agent sends none of them, and a heartbeat
  # carrying none writes NO document at all, which stays distinguishable from
  # every reported state. An unrecognized mount_state stores nil rather than
  # being coerced toward a plausible-looking match, and an out-of-range
  # cpu_pct is refused for the same reason: a broken producer must not put a
  # fabricated number into ProjectMetricsCollector's mean.
  #
  # EACH QUALIFYING TICK WRITES A FRESH SNAPSHOT, never a merge onto the
  # previous document, so a field that stops being reported DISAPPEARS on the
  # next QUALIFYING heartbeat rather than lingering as a stale positive — the
  # same reasoning that made a frozen "armed" the defect in
  # System::BootLkgStateWriter. When a heartbeat reports none of them, no
  # write happens at all and the previous document persists with its old
  # observed_at until a reader's freshness window retires it; that is the same
  # shape as a missed heartbeat and is why every reader must check observed_at
  # rather than trusting the document's presence.
  #
  # Writes ONE top-level config key through the guarded-UPDATE idiom shared
  # with Sdwan::AgentApplyStateWriter and System::BootLkgStateWriter, so it
  # cannot erase what another writer put in config during the same request.
  class RuntimeMetricsWriter
    CONFIG_KEY = "runtime_metrics"

    # The keys the controller slices out of the heartbeat params.
    WIRE_KEYS = %w[mount_state load_average memory_free_kb uptime_seconds cpu_pct].freeze

    # heartbeat.go:30 documents exactly these three. Anything else is a
    # producer the server does not understand, and guessing at it would put a
    # fabricated state under a key a sensor may later gate on.
    MOUNT_STATES = %w[mounted unmounted transitioning].freeze

    # load_average arrives as a formatted string ("0.15 0.20 0.10"); bound it
    # so an unbounded node-controlled value cannot reach a read surface.
    MAX_LOAD_AVERAGE_CHARS = 64
    MAX_INTEGER_DIGITS = 19

    # cpu_pct is a PERCENTAGE the node measured (agent cpuSampler), so the
    # domain is closed: anything outside 0..100 is a broken producer, not a
    # reading, and is stored as nil (unreported) rather than clamped. Clamping
    # would publish a fabricated 100 or 0 that a sensor cannot tell from a
    # real one.
    MAX_PERCENT = 100.0

    class << self
      def write!(instance:, payload:)
        return false if instance.nil?

        readable = normalize(payload)
        return false unless readable.values.any? { |v| !v.nil? }

        document = readable.merge("observed_at" => Time.current.utc.iso8601)
        merge_config_key!(instance, document)
      end

      private

      def normalize(payload)
        {
          "mount_state" => mount_state(fetch(payload, :mount_state)),
          "load_average" => load_average(fetch(payload, :load_average)),
          "memory_free_kb" => integer_or_nil(fetch(payload, :memory_free_kb)),
          "uptime_seconds" => integer_or_nil(fetch(payload, :uptime_seconds)),
          "cpu_pct" => percent_or_nil(fetch(payload, :cpu_pct))
        }
      end

      def mount_state(raw)
        value = raw.to_s.strip.downcase
        MOUNT_STATES.include?(value) ? value : nil
      end

      def load_average(raw)
        return nil if raw.nil?

        value = raw.to_s.strip
        return nil if value.empty? || value.length > MAX_LOAD_AVERAGE_CHARS

        value
      end

      # A measured 0.0 (a genuinely idle node) must survive as a reading —
      # only nil means unreported — so this returns 0.0, never nil, for a
      # legitimate zero. Strings are accepted because a JSON body can spell a
      # number that way; a non-numeric string is not coerced ("busy".to_f is
      # 0.0, which would publish maximum headroom as a measurement).
      def percent_or_nil(raw)
        return nil if raw.nil?
        return nil unless raw.is_a?(Numeric) || raw.to_s.strip.match?(/\A\d{1,3}(\.\d+)?\z/)

        value = Float(raw)
        return nil unless value.finite?
        return nil if value.negative? || value > MAX_PERCENT

        value.round(2)
      rescue ArgumentError, TypeError
        nil
      end

      def integer_or_nil(raw)
        return nil if raw.nil?
        # No leading minus: both fields are counters (free KB, seconds up) and a
        # negative is never a valid reading. The collector defends itself too,
        # but this is the sanitization layer.
        return nil unless raw.to_s.strip.match?(/\A\d{1,#{MAX_INTEGER_DIGITS}}\z/o)

        Integer(raw.to_s.strip, 10)
      rescue ArgumentError, TypeError
        nil
      end

      # Tries both key forms: the controller passes the parsed heartbeat body
      # (indifferent access), specs and internal callers pass a plain
      # symbol-keyed hash, and a symbol-keyed hash silently reading as
      # "reported nothing" would be a false green.
      def fetch(entry, key)
        return nil if entry.nil?

        value = entry[key.to_sym]
        value.nil? ? entry[key.to_s] : value
      rescue TypeError, NoMethodError
        nil
      end

      # Same guarded-UPDATE idiom as the two sibling writers. No
      # allow_first_write guard is needed here: unlike the boot-LKG document,
      # whose whole point is that absence must not create a record, this
      # document is a plain observation and the first qualifying tick SHOULD
      # create it.
      def merge_config_key!(instance, document)
        ::System::NodeInstance
          .where(id: instance.id)
          .update_all([
            "config = jsonb_set(COALESCE(config, '{}'::jsonb), ARRAY[?], ?::jsonb, true)",
            CONFIG_KEY, document.to_json
          ]).positive?
      end
    end
  end
end
