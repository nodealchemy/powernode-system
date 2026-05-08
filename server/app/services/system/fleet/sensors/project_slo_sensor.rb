# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Watches active infrastructure missions (the "project" abstraction
      # introduced by the AI-driven provisioning conversation) and emits one
      # of three signal kinds when their declared SLO targets are breached:
      #
      #   - `system.project_slo_violation` — observed metric outside target
      #     window (latency, availability, etc.)
      #   - `system.project_drift`         — runtime configuration drift
      #     against the captured Project Brief (region count, replica count)
      #   - `system.project_cost_breach`   — month-to-date cost trending
      #     above `slo_targets["cost_ceiling_usd"]` or `budget_cap_usd_monthly`
      #
      # The DecisionEngine routes these to `project.adapt` /
      # `project.cost_control` action_categories. AdaptationProposerService
      # then turns the signal payload into a diff plan that runs through the
      # Slice B provisioning skill executors.
      #
      # Cadence: piggybacks on `FleetAutonomyService.tick!` (60s). No metrics
      # backend exists yet — when `MetricsClient` is unavailable the sensor
      # reads any test-injected observations off `mission.configuration
      # ["latest_observations"]` (M0/M1 sanity path), then falls through to
      # the no-op (returns `[]`) so production tick! cycles stay quiet until
      # a real metrics service plugs in.
      class ProjectSloSensor < BaseSensor
        # Default targets when the brief / mission.configuration["slo_targets"]
        # doesn't supply them. These mirror the side-business persona quality
        # bar from the provisioning plan.
        DEFAULT_AVAILABILITY_PCT  = 99.5
        DEFAULT_P99_LATENCY_MS    = 250
        DEFAULT_COST_CEILING_USD  = nil # falls back to brief.budget_cap_usd_monthly

        # Severity scaling — breach % over target threshold.
        SEVERITY_THRESHOLDS = [
          [50.0, :critical], # ≥50% above target → critical
          [25.0, :high],     # ≥25% → high
          [10.0, :medium]    # ≥10% → medium
          # else :low
        ].freeze

        def sense
          missions = ::Ai::Mission
            .where(account_id: account.id, mission_type: "infrastructure", status: "active")

          missions.find_each.flat_map { |m| evaluate_mission(m) }.compact
        rescue StandardError => e
          Rails.logger.warn("[ProjectSloSensor] failed: #{e.class}: #{e.message}")
          []
        end

        private

        # Returns 0..3 signals per mission. Each metric is checked
        # independently; the sensor never short-circuits.
        def evaluate_mission(mission)
          targets       = extract_targets(mission)
          observations  = sample_observations(mission)
          correlation   = build_correlation_id(mission)

          [
            slo_violation_signal(mission, targets, observations, correlation),
            drift_signal(mission, targets, observations, correlation),
            cost_breach_signal(mission, targets, observations, correlation)
          ]
        rescue StandardError => e
          Rails.logger.warn("[ProjectSloSensor] mission=#{mission.id} eval failed: #{e.message}")
          []
        end

        # ----- target extraction --------------------------------------------

        def extract_targets(mission)
          cfg = mission.configuration.is_a?(Hash) ? mission.configuration.deep_stringify_keys : {}
          slo  = cfg["slo_targets"].is_a?(Hash) ? cfg["slo_targets"] : {}
          brief = cfg["brief"].is_a?(Hash) ? cfg["brief"] : {}

          {
            "availability_pct" => slo["availability_pct"]&.to_f || DEFAULT_AVAILABILITY_PCT,
            "p99_latency_ms" => slo["p99_latency_ms"]&.to_f ||
                                  brief.dig("latency_targets_ms", "p99")&.to_f ||
                                  DEFAULT_P99_LATENCY_MS.to_f,
            "cost_ceiling_usd" => (slo["cost_ceiling_usd"] || brief["budget_cap_usd_monthly"])&.to_f,
            "expected_replica_count" => brief.dig("scale", "initial")&.to_i,
            "expected_region_count" => Array(brief["regions"]).size
          }
        end

        # Pull the latest observation tuple. Production metrics live in
        # `System::ProjectMetric` (written by `ProjectMetricsCollector` on
        # each FleetAutonomyService.tick!). Tests and bootstrap accounts
        # without a metrics history fall back to the synthetic observation
        # blob on `configuration["latest_observations"]` — the M0/M1/M2
        # specs use this seam and must keep passing.
        def sample_observations(mission)
          db_obs = sample_from_db(mission)
          return db_obs if db_obs && db_obs.values.any? { |v| !v.nil? }

          sample_from_config(mission)
        end

        # Reads the latest sample per metric_name from `system_project_metrics`
        # and maps the canonical metric vocabulary back to the sensor's
        # observation hash shape (which uses `actual_*` and
        # `month_to_date_cost_usd` keys for historical reasons).
        def sample_from_db(mission)
          return nil unless defined?(::System::ProjectMetric)

          rows = ::System::ProjectMetric.recent_for_mission(mission.id)
          by_name = rows.each_with_object({}) { |row, h| h[row.metric_name] = row.observed }

          return nil if by_name.empty?
          return nil if by_name.values.all? { |v| v.nil? || (v.respond_to?(:zero?) && v.zero?) }

          {
            "availability_pct" => by_name["availability_pct"]&.to_f,
            "p99_latency_ms" => by_name["p99_latency_ms"]&.to_f,
            "month_to_date_cost_usd" => by_name["cost_usd_mtd"]&.to_f,
            "actual_replica_count" => by_name["replica_count"]&.to_i,
            "actual_region_count" => by_name["region_count"]&.to_i
          }
        rescue StandardError => e
          Rails.logger.warn("[ProjectSloSensor] DB metrics read failed for mission=#{mission.id}: #{e.message}")
          nil
        end

        def sample_from_config(mission)
          cfg = mission.configuration.is_a?(Hash) ? mission.configuration.deep_stringify_keys : {}
          obs = cfg["latest_observations"].is_a?(Hash) ? cfg["latest_observations"] : {}

          {
            "availability_pct" => obs["availability_pct"]&.to_f,
            "p99_latency_ms" => obs["p99_latency_ms"]&.to_f,
            "month_to_date_cost_usd" => obs["month_to_date_cost_usd"]&.to_f,
            "actual_replica_count" => obs["actual_replica_count"]&.to_i,
            "actual_region_count" => obs["actual_region_count"]&.to_i
          }
        end

        # ----- signal builders ----------------------------------------------

        def slo_violation_signal(mission, targets, obs, correlation)
          # Pick the first violated metric. Latency over-target is the most
          # common signal; availability under-target the most severe.
          if obs["p99_latency_ms"].present? && obs["p99_latency_ms"] > targets["p99_latency_ms"]
            breach_pct = pct_over(obs["p99_latency_ms"], targets["p99_latency_ms"])
            return build_signal(
              kind: "system.project_slo_violation",
              severity: severity_for(breach_pct),
              payload: {
                mission_id: mission.id,
                metric: "p99_latency_ms",
                observed: obs["p99_latency_ms"],
                target: targets["p99_latency_ms"],
                breach_pct: breach_pct,
                correlation_id: correlation
              },
              fingerprint: "project_slo_violation:#{mission.id}:p99_latency_ms"
            )
          end

          if obs["availability_pct"].present? && obs["availability_pct"] < targets["availability_pct"]
            breach_pct = pct_under(obs["availability_pct"], targets["availability_pct"])
            return build_signal(
              kind: "system.project_slo_violation",
              severity: severity_for(breach_pct),
              payload: {
                mission_id: mission.id,
                metric: "availability_pct",
                observed: obs["availability_pct"],
                target: targets["availability_pct"],
                breach_pct: breach_pct,
                correlation_id: correlation
              },
              fingerprint: "project_slo_violation:#{mission.id}:availability_pct"
            )
          end

          nil
        end

        def drift_signal(mission, targets, obs, correlation)
          drift_type, observed, target = detect_drift(targets, obs)
          return nil if drift_type.nil?

          build_signal(
            kind: "system.project_drift",
            severity: :medium,
            payload: {
              mission_id: mission.id,
              drift_type: drift_type,
              observed: observed,
              target: target,
              correlation_id: correlation
            },
            fingerprint: "project_drift:#{mission.id}:#{drift_type}"
          )
        end

        def detect_drift(targets, obs)
          if targets["expected_replica_count"].to_i.positive? &&
             obs["actual_replica_count"].present? &&
             obs["actual_replica_count"] != targets["expected_replica_count"]
            return [ "replica_count", obs["actual_replica_count"], targets["expected_replica_count"] ]
          end

          if targets["expected_region_count"].to_i.positive? &&
             obs["actual_region_count"].present? &&
             obs["actual_region_count"] != targets["expected_region_count"]
            return [ "region_count", obs["actual_region_count"], targets["expected_region_count"] ]
          end

          [ nil, nil, nil ]
        end

        def cost_breach_signal(mission, targets, obs, correlation)
          ceiling = targets["cost_ceiling_usd"]
          observed = obs["month_to_date_cost_usd"]
          return nil if ceiling.nil? || ceiling <= 0
          return nil if observed.nil? || observed <= ceiling

          breach_pct = pct_over(observed, ceiling)
          build_signal(
            kind: "system.project_cost_breach",
            severity: severity_for(breach_pct),
            payload: {
              mission_id: mission.id,
              observed_usd: observed,
              target_usd: ceiling,
              breach_pct: breach_pct,
              correlation_id: correlation
            },
            fingerprint: "project_cost_breach:#{mission.id}"
          )
        end

        # ----- helpers ------------------------------------------------------

        def build_signal(kind:, severity:, payload:, fingerprint:)
          signal(kind: kind, severity: severity, payload: payload, fingerprint: fingerprint)
        end

        def severity_for(breach_pct)
          SEVERITY_THRESHOLDS.each do |threshold, sev|
            return sev if breach_pct >= threshold
          end
          :low
        end

        def pct_over(observed, target)
          return 0.0 if target.to_f <= 0
          (((observed.to_f - target.to_f) / target.to_f) * 100).round(2)
        end

        def pct_under(observed, target)
          return 0.0 if target.to_f <= 0
          (((target.to_f - observed.to_f) / target.to_f) * 100).round(2)
        end

        def build_correlation_id(mission)
          # Deterministic per-tick-per-mission correlation id; sensor ticks
          # run every 60s so coalescing signals to the same correlation
          # bucket per minute is the right granularity.
          bucket = (Time.current.to_i / 60).to_s
          "project_slo:#{mission.id}:#{bucket}"
        end
      end
    end
  end
end
