# frozen_string_literal: true

module System
  module Metrics
    # Counter-based metrics aggregator (v1 — Phase 10.5).
    #
    # Backed by Rails.cache (Redis in production, memory in test) with
    # per-minute bucket granularity. Each `record` call increments a
    # counter keyed by (metric_name, account_id, minute_bucket); reads
    # sum buckets across a time window.
    #
    # Why not Redis ZSET / percentile histograms in v1: ops/sec is the
    # most operationally useful first metric, and Rails.cache works on
    # both Puma (server) and Sidekiq (worker) without a raw-redis
    # adapter. Percentile histograms are a v2 enhancement.
    #
    # Scoped per-account so multi-tenant operators see only their data.
    # Non-account-scoped events (system-level dispatch) use account_id=nil
    # and are stored under a "_system" namespace.
    #
    # Reference: comprehensive stabilization sweep Phase 10.5; pinned plan
    # at `~/.claude/plans/read-tasks-md-and-system-review-and-plan-snug-rainbow.md`.
    class Aggregator
      BUCKET_SECONDS = 60
      DEFAULT_TTL = 65 * 60 # 65 minutes — covers 1h window with margin
      MAX_WINDOW = 1.hour

      class << self
        # Record a single metric occurrence. Best-effort; never raises.
        #
        # @param metric_name [String] dotted name (e.g. "system.dispatch.completed")
        # @param account_id [String, nil] tenant scope; nil for system-level events
        # @param value [Integer] counter increment (default 1)
        # @param at [Time] timestamp (default Time.current; mostly for tests)
        def record(metric_name:, account_id: nil, value: 1, at: Time.current)
          return unless metric_name.present?

          bucket = at.to_i / BUCKET_SECONDS
          key = bucket_key(metric_name, account_id, bucket)
          Rails.cache.increment(key, value, expires_in: DEFAULT_TTL, initial: 0)
        rescue StandardError => e
          Rails.logger.warn("[Metrics::Aggregator] record failed: #{e.class}: #{e.message}")
          nil
        end

        # Read aggregated stats over a time window.
        #
        # @param metric_name [String]
        # @param account_id [String, nil]
        # @param window [ActiveSupport::Duration] default 5.minutes, capped at 1.hour
        # @return [Hash] { count:, rate_per_sec:, window_seconds:, buckets: [{ts:, count:}, ...] }
        def stats(metric_name:, account_id: nil, window: 5.minutes, at: Time.current)
          window = [ window.to_i, MAX_WINDOW.to_i ].min
          end_bucket = at.to_i / BUCKET_SECONDS
          start_bucket = end_bucket - (window / BUCKET_SECONDS) + 1

          buckets = (start_bucket..end_bucket).map do |b|
            count = read_bucket(metric_name, account_id, b)
            { ts: b * BUCKET_SECONDS, count: count }
          end

          total = buckets.sum { |b| b[:count] }
          {
            count: total,
            rate_per_sec: window.zero? ? 0.0 : (total.to_f / window).round(4),
            window_seconds: window,
            buckets: buckets
          }
        end

        # Aggregate across multiple metric names (e.g. all `system.dispatch.*`).
        # Returns a hash keyed by metric name.
        def stats_for_names(metric_names, account_id: nil, window: 5.minutes, at: Time.current)
          metric_names.each_with_object({}) do |name, memo|
            memo[name] = stats(metric_name: name, account_id: account_id, window: window, at: at)
          end
        end

        # Test helper. Wipes recorded buckets for the metric+account scope.
        # Production callers shouldn't need this — TTL handles cleanup.
        def reset!(metric_name:, account_id: nil, at: Time.current)
          end_bucket = at.to_i / BUCKET_SECONDS
          start_bucket = end_bucket - (MAX_WINDOW.to_i / BUCKET_SECONDS)

          (start_bucket..end_bucket).each do |b|
            Rails.cache.delete(bucket_key(metric_name, account_id, b))
          end
        end

        private

        def bucket_key(metric_name, account_id, bucket)
          "system_metric:#{metric_name}:#{account_id || '_system'}:#{bucket}"
        end

        def read_bucket(metric_name, account_id, bucket)
          raw = Rails.cache.read(bucket_key(metric_name, account_id, bucket), raw: true)
          raw.to_i
        rescue StandardError
          0
        end
      end
    end
  end
end
