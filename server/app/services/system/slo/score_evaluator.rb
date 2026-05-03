# frozen_string_literal: true

module System
  module Slo
    # Evaluates each SLO Definition against observed fleet data and returns
    # a structured result that callers (the SloViolationSensor in particular)
    # can act on.
    #
    # v0 evaluator uses signals already in System::FleetEvent + heartbeat
    # gaps as proxies. Real metric-driven evaluation (CPU, memory, request
    # rate, error count) lands with M-D2-2 telemetry pipeline. Interface is
    # stable so the v0 stub can be swapped without touching the sensor.
    class ScoreEvaluator
      Score = Struct.new(:definition, :uptime_pct, :error_rate_pct, :latency_p99_ms,
                         :violations, :within_target, keyword_init: true)

      def self.evaluate_all(account:)
        new.evaluate_all(account: account)
      end

      def evaluate_all(account:)
        ::System::Slo::Definition
          .joins(:node_module)
          .where(system_node_modules: { account_id: account.id })
          .map { |defn| evaluate(defn) }
      end

      def evaluate(defn)
        cutoff = Time.current - defn.window_seconds

        # Uptime proxy: compute the fraction of instances that received any
        # heartbeat in the window. Modules attached to instances with no
        # heartbeat for the whole window are scored as 0% uptime.
        instance_count, healthy_count = uptime_metrics(defn.node_module, cutoff)
        uptime_pct = instance_count.zero? ? nil : ((healthy_count * 100.0) / instance_count).round(2)

        # Error rate proxy: count of decision.pending + decision.blocked +
        # *_failed FleetEvents tied to the module / 100, capped at 100.
        error_count = error_event_count(defn.node_module, cutoff)
        signal_count = signal_event_count(defn.node_module, cutoff)
        denom = signal_count.zero? ? 1 : signal_count
        error_rate_pct = ((error_count * 100.0) / denom).round(2)

        # Latency proxy: not measurable from FleetEvents alone; left nil
        # until M-D2-2. The sensor doesn't fire on nil values.
        latency_p99_ms = nil

        violations = []
        if defn.uptime_target_pct && uptime_pct && uptime_pct < defn.uptime_target_pct.to_f
          violations << { metric: "uptime_pct", target: defn.uptime_target_pct.to_f, observed: uptime_pct }
        end
        if defn.error_rate_max_pct && error_rate_pct > defn.error_rate_max_pct.to_f
          violations << { metric: "error_rate_pct", target: defn.error_rate_max_pct.to_f, observed: error_rate_pct }
        end
        if defn.latency_p99_max_ms && latency_p99_ms && latency_p99_ms > defn.latency_p99_max_ms
          violations << { metric: "latency_p99_ms", target: defn.latency_p99_max_ms, observed: latency_p99_ms }
        end

        Score.new(
          definition: defn,
          uptime_pct: uptime_pct,
          error_rate_pct: error_rate_pct,
          latency_p99_ms: latency_p99_ms,
          violations: violations,
          within_target: violations.empty?
        )
      end

      private

      def uptime_metrics(node_module, cutoff)
        instance_ids = node_module.node_module_assignments
                                  .joins(node: :node_instances)
                                  .pluck("system_node_instances.id").uniq
        return [ 0, 0 ] if instance_ids.empty?

        healthy = ::System::NodeInstance
                  .where(id: instance_ids)
                  .where("last_heartbeat_at IS NOT NULL AND last_heartbeat_at >= ?", cutoff)
                  .count
        [ instance_ids.size, healthy ]
      end

      def error_event_count(node_module, cutoff)
        return 0 unless defined?(::System::FleetEvent)
        ::System::FleetEvent
          .where(node_module_id: node_module.id)
          .where("emitted_at >= ?", cutoff)
          .where("kind LIKE 'decision.blocked' OR kind LIKE 'decision.pending' OR kind LIKE '%failed'")
          .count
      end

      def signal_event_count(node_module, cutoff)
        return 0 unless defined?(::System::FleetEvent)
        ::System::FleetEvent
          .where(node_module_id: node_module.id)
          .where("emitted_at >= ?", cutoff)
          .count
      end
    end
  end
end
