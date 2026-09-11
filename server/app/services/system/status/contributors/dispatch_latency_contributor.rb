# frozen_string_literal: true

module System
  module Status
    module Contributors
      # The dispatch pipeline, one component per account (campaign 01a08c9b B5,
      # checklist row 22). It reads DispatchLatencyTile's data:
      # System::Metrics::Aggregator's Rails.cache counters over the tile's
      # window, scoped to the account the way MetricsController#index scopes
      # them.
      #
      # ── WHY A ROUND TRIP FIRST ──────────────────────────────────────────
      # Aggregator.read_bucket rescues every error to 0 (aggregator.rb:96-101),
      # so a cache outage reads exactly like a quiet window. Before trusting a
      # zero, this writes a probe key, reads it back and deletes it. A failed
      # round trip is not_measured with reason CacheUnavailable, and the counts
      # are withheld. A round trip that works with counters at 0 is a MEASURED
      # quiet window: zero dispatches, and ok. The counter writer is untouched.
      #
      # ── THE THRESHOLD ───────────────────────────────────────────────────
      # The tile's own: failurePercent = failed / (completed + failed), and the
      # badge turns danger above 5 (DispatchLatencyTile.tsx:58-63 and :72).
      # Above it is degraded. There is no other number. The ratio is taken over
      # counts: the tile's rates are the same counts over the same window, so
      # the ratio is identical without the rates' rounding.
      class DispatchLatencyContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND = "dispatch_latency"
        REF  = "dispatch_pipeline"

        AGGREGATOR = ::System::Metrics::Aggregator

        # The tile's window and tracked names (DispatchLatencyTile.tsx:15-21).
        WINDOW = 300.seconds
        TRACKED = %w[
          system.dispatch.claimed
          system.dispatch.started
          system.dispatch.completed
          system.dispatch.failed
          system.fleet.event
        ].freeze
        COMPLETED = "system.dispatch.completed"
        FAILED    = "system.dispatch.failed"

        # DispatchLatencyTile.tsx:72, `failurePercent > 5`.
        FAILURE_PERCENT_THRESHOLD = 5

        CACHE    = "CacheReachable"
        FAILURES = "FailureRate"

        PROBE_KEY = "system_status:dispatch_latency:round_trip"
        # Only a backstop for a delete that failed; the key is deleted at once.
        PROBE_TTL = 1.minute

        Pipeline = Struct.new(:account, keyword_init: true)

        def kind = KIND

        def account_scoped? = true

        # Design §5.4: fleet kinds keep their own lane's escalation.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          yield Pipeline.new(account: account)
        end

        def ref_for(_record) = REF

        def display_name_for(_record) = "Dispatch pipeline"

        def presentation
          { "icon" => "Timer", "label" => "Dispatch pipeline", "group_order" => 120 }
        end

        def conditions_for(record)
          now = Time.current
          round_trip = cache_round_trip
          return [ cache_down(round_trip, now), failures_withheld(now) ] unless round_trip[:ok]

          stats = AGGREGATOR.stats_for_names(TRACKED, account_id: record.account.id, window: WINDOW, at: now)
          [ cache_up(now), failure_rate(stats, now) ]
        end

        private

        def cache_round_trip
          key = "#{PROBE_KEY}:#{SecureRandom.hex(8)}"
          token = SecureRandom.hex(8)
          Rails.cache.write(key, token, expires_in: PROBE_TTL)
          read = Rails.cache.read(key)
          return { ok: true } if read == token

          { ok: false, error: "wrote a probe value and read back #{read.nil? ? 'nothing' : 'a different value'}" }
        rescue StandardError => e
          { ok: false, error: "#{e.class}: #{e.message}" }
        ensure
          begin
            Rails.cache.delete(key) if key
          rescue StandardError
            nil
          end
        end

        def cache_up(now)
          CONDITION.build(type: CACHE, status: true, reason: "RoundTripOk",
                          evidence: { "source" => "Rails.cache write, read and delete of a probe key" }, now: now)
        end

        def cache_down(round_trip, now)
          CONDITION.build(
            type: CACHE,
            status: CONDITION::UNKNOWN,
            reason: "CacheUnavailable",
            message: "the metrics cache failed a round trip: #{round_trip[:error]}",
            evidence: { "source" => "Rails.cache write, read and delete of a probe key", "error" => round_trip[:error] },
            now: now
          )
        end

        def failures_withheld(now)
          CONDITION.build(
            type: FAILURES,
            status: CONDITION::UNKNOWN,
            reason: "CacheUnavailable",
            message: "Aggregator.read_bucket reads a cache failure as 0, so the counters would be a guess; withheld",
            evidence: { "counts_withheld" => true },
            now: now
          )
        end

        def failure_rate(stats, now)
          counts = TRACKED.index_with { |name| stats.fetch(name).fetch(:count) }
          rates  = TRACKED.index_with { |name| stats.fetch(name).fetch(:rate_per_sec) }
          finished = counts.fetch(COMPLETED) + counts.fetch(FAILED)
          percent = finished.positive? ? (counts.fetch(FAILED).to_f / finished * 100) : 0.0
          evidence = {
            "source" => "System::Metrics::Aggregator, Rails.cache per-minute buckets, account-scoped as MetricsController#index",
            "window_seconds" => WINDOW.to_i,
            "counts" => counts,
            "rates_per_sec" => rates,
            "failure_percent" => percent.round(2),
            "threshold_percent" => FAILURE_PERCENT_THRESHOLD,
            "threshold_source" => "DispatchLatencyTile.tsx:72 (failurePercent > 5)"
          }

          if percent > FAILURE_PERCENT_THRESHOLD
            CONDITION.build(
              type: FAILURES, status: false, reason: "FailureRateHigh", severity: CONDITION::SEVERITY_DEGRADED,
              message: "#{percent.round(1)}% of finished dispatches failed in the last #{WINDOW.to_i / 60}m " \
                       "(above #{FAILURE_PERCENT_THRESHOLD}%)",
              evidence: evidence, now: now
            )
          else
            CONDITION.build(type: FAILURES, status: true, reason: finished.positive? ? "FailureRateOk" : "QuietWindow",
                            evidence: evidence, now: now)
          end
        end
      end
    end
  end
end
