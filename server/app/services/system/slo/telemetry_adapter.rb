# frozen_string_literal: true

module System
  module Slo
    # Audit plan P2.8a — replaces the `latency_p99_ms = nil` stub in
    # ScoreEvaluator#evaluate with a real reader. Reads FleetEvent rows
    # tagged `kind="metric.latency_ms"` scoped to the target node_module
    # and computes the 99th-percentile sample value across the window.
    #
    # Forward-compatible: when M-D2-2 telemetry lands (per ProjectMetricsCollector's
    # TODO(metrics-backend) note), real samplers can write FleetEvent rows
    # with this kind + payload shape, and this adapter picks them up without
    # source-code changes. Until then, the adapter returns nil for modules
    # with no observed samples — exactly the no-op behavior the SloViolationSensor
    # expects.
    #
    # Event convention:
    #   kind:    "metric.latency_ms"
    #   payload: { "value" => <Float ms>, "node_module_id" => <uuid> }
    #
    # The node_module association comes from either:
    #   - FleetEvent.node_module_id column directly (preferred — indexed), OR
    #   - payload["node_module_id"] as fallback for samplers that aren't
    #     yet wired into the typed-association columns.
    class TelemetryAdapter
      LATENCY_EVENT_KIND = "metric.latency_ms"

      def self.latency_p99_ms(node_module:, since:)
        new(node_module: node_module, since: since).latency_p99_ms
      end

      def initialize(node_module:, since:)
        @node_module = node_module
        @since = since
      end

      def latency_p99_ms
        samples = collect_latency_samples
        return nil if samples.empty?

        percentile(samples, 0.99).round(2)
      end

      private

      def collect_latency_samples
        # Account-scoped + module-scoped + time-windowed query. Prefer the
        # indexed node_module_id column; fall back to payload jsonb match
        # for samplers that route through generic payload.
        events = ::System::FleetEvent
                   .where(account_id: @node_module.account_id, kind: LATENCY_EVENT_KIND)
                   .where("emitted_at >= ? OR (emitted_at IS NULL AND created_at >= ?)", @since, @since)
                   .where("node_module_id = ? OR payload->>'node_module_id' = ?",
                          @node_module.id, @node_module.id.to_s)

        events.find_each.flat_map do |event|
          value = event.payload.is_a?(Hash) ? event.payload["value"] : nil
          next [] if value.nil?

          Array(value).map { |v| Float(v) rescue nil }.compact
        end
      end

      # Linear-interpolation percentile per the standard "C=1" definition.
      # Caller passes a probability in [0, 1]; we return the interpolated
      # sample. Robust to small N — `percentile([10, 20, 30], 0.99)` returns
      # 29.6 rather than the next-higher integer that nearest-rank would give.
      def percentile(samples, probability)
        sorted = samples.sort
        return sorted.first if sorted.size == 1

        rank = probability * (sorted.size - 1)
        lower = sorted[rank.floor]
        upper = sorted[rank.ceil]
        fraction = rank - rank.floor
        lower + (upper - lower) * fraction
      end
    end
  end
end
