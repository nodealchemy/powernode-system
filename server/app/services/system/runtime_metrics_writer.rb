# frozen_string_literal: true

module System
  # Ingests the four scalar runtime fields the agent has always sent and the
  # server has always discarded: mount_state, load_average, memory_free_kb,
  # uptime_seconds (heartbeat.go:28-32).
  #
  # status_controller's own doc comment listed all four as accepted body
  # fields, and System::ProjectMetricsCollector named this exact source for
  # cpu_pct/memory_pct ("node agent heartbeat") — so the measurement landed
  # every 30 seconds and was thrown away while the metric reported
  # `unavailable` forever.
  #
  # ABSENCE IS NOT A MEASUREMENT. `mount_state` and `uptime_seconds` are sent
  # unconditionally, but the other two are Go `omitempty`, and a pre-feature
  # agent sends none of the four. A heartbeat carrying none of them writes NO
  # document at all, which stays distinguishable from every reported state.
  # An unrecognized mount_state stores nil rather than being coerced toward a
  # plausible-looking match.
  #
  # EACH QUALIFYING TICK WRITES A FRESH SNAPSHOT, never a merge onto the
  # previous document, so a field that stops being reported DISAPPEARS on the
  # next QUALIFYING heartbeat rather than lingering as a stale positive — the
  # same reasoning that made a frozen "armed" the defect in
  # System::BootLkgStateWriter. When a heartbeat reports none of the four, no
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
    WIRE_KEYS = %w[mount_state load_average memory_free_kb uptime_seconds].freeze

    # heartbeat.go:30 documents exactly these three. Anything else is a
    # producer the server does not understand, and guessing at it would put a
    # fabricated state under a key a sensor may later gate on.
    MOUNT_STATES = %w[mounted unmounted transitioning].freeze

    # load_average arrives as a formatted string ("0.15 0.20 0.10"); bound it
    # so an unbounded node-controlled value cannot reach a read surface.
    MAX_LOAD_AVERAGE_CHARS = 64
    MAX_INTEGER_DIGITS = 19

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
          "uptime_seconds" => integer_or_nil(fetch(payload, :uptime_seconds))
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

      # Tries both key forms: the controller passes an
      # ActionController::Parameters, specs and internal callers pass a plain
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
