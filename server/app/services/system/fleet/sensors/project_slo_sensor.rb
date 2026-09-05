# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Watches active infrastructure missions (the "project" abstraction
      # introduced by the AI-driven provisioning conversation) and emits one
      # of three signal kinds when their declared SLO targets are breached:
      #
      #   - `system.project_slo_violation` — observed metric outside target
      #     window (latency, availability, SDWAN throughput floor)
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

        # IMP-7684d3f8658a — the utilization metrics this sensor checks against
        # a ceiling, in the order they are evaluated, mapped to the target key
        # #extract_targets resolves from Ai::Mission#utilization_targets. CPU
        # first: it is the metric a scale-out actually relieves.
        UTILIZATION_METRICS = [
          [ "cpu_pct", "max_cpu_pct" ],
          [ "memory_pct", "max_memory_pct" ]
        ].freeze

        # Severity scaling — breach % over target threshold.
        SEVERITY_THRESHOLDS = [
          [ 50.0, :critical ], # ≥50% above target → critical
          [ 25.0, :high ],     # ≥25% → high
          [ 10.0, :medium ]    # ≥10% → medium
          # else :low
        ].freeze

        def sense
          # `.includes` because #extract_targets walks each mission's
          # utilization ladder, which touches the mission TEMPLATE and the
          # ACCOUNT rungs — a bare relation makes that two extra SELECTs per
          # mission per tick.
          missions = ::Ai::Mission
            .includes(:mission_template, :account)
            .where(account_id: account.id, mission_type: "infrastructure", status: "active")

          # The SiteSetting rung of that same ladder, read ONCE for the whole
          # tick: it is a per-deployment value, and SiteSetting.get is an
          # uncached find_by. See Ai::Mission.global_utilization_settings.
          @global_utilization_settings = resolve_global_utilization_settings

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
            "expected_region_count" => Array(brief["regions"]).size,
            # IMP-25e75f960dee — SDWAN throughput floor. NO DEFAULT, on purpose:
            # unlike latency/availability there is no universally sane minimum
            # rate for a tunnel, and a defaulted floor would fire on every
            # mission the moment the metric went live. Declared-only, exactly
            # like cost_ceiling_usd — so a mission that says nothing keeps its
            # current behaviour byte for byte.
            "min_throughput_bytes_per_s" => slo["min_throughput_bytes_per_s"]&.to_f
          }.merge(utilization_targets_for(mission))
        end

        # IMP-7684d3f8658a — the cpu / memory ceilings, read from the mission
        # rather than re-derived here. `Ai::Mission#utilization_targets` is the
        # bounds home APO-3a established, and it already resolves the whole
        # ladder (the project's own `slo_targets` → its template →
        # Account#settings → SiteSetting → constant). Re-reading `slo` here
        # instead would give this sensor a private, shallower opinion of a
        # project's declared ceiling than the model every other reader uses.
        #
        # nil for a metric means NO ceiling was usably declared and the metric
        # is not checked at all — see Ai::Mission#resolved_utilization_target.
        # `respond_to?` because a core without the targets (an older deploy of
        # the model, or a mission double in a spec) must leave the sensor's
        # existing metrics working rather than take the whole mission's
        # evaluation down.
        def utilization_targets_for(mission)
          return {} unless mission.respond_to?(:utilization_targets)

          targets = mission.utilization_targets(global_settings: @global_utilization_settings)
          {
            "max_cpu_pct" => targets.target_for("cpu_pct"),
            "max_memory_pct" => targets.target_for("memory_pct")
          }
        rescue StandardError => e
          Rails.logger.warn("[ProjectSloSensor] utilization targets unresolved for " \
                            "mission=#{mission.id}: #{e.class}: #{e.message}")
          {}
        end

        # nil (not {}) when the hoist is unavailable — a core without it, or a
        # read that failed — because nil means "not supplied" to the ladder,
        # which then resolves the rung itself. An empty hash would instead
        # assert "resolved, nothing set" and suppress a real SiteSetting.
        def resolve_global_utilization_settings
          return nil unless ::Ai::Mission.respond_to?(:global_utilization_settings)

          ::Ai::Mission.global_utilization_settings
        rescue StandardError => e
          Rails.logger.warn("[ProjectSloSensor] global utilization settings unresolved: " \
                            "#{e.class}: #{e.message}")
          nil
        end

        # Pull the latest observation tuple. Production metrics live in
        # `System::ProjectMetric` (written by `ProjectMetricsCollector` on
        # each FleetAutonomyService.tick!). Tests and bootstrap accounts
        # without a metrics history fall back to the synthetic observation
        # blob on `configuration["latest_observations"]` — the M0/M1/M2
        # specs use this seam and must keep passing.
        # The DB arm wins whenever it carries ANY real reading. Note that this
        # test reads the MAPPED hash, so IMP-7684d3f8658a widened it: a mission
        # whose only non-nil ProjectMetric rows are cpu_pct / memory_pct used to
        # fall through to the synthetic config blob and now does not. That is
        # the intended direction — the config seam is documented above as the
        # fallback for a mission with NO metrics history, and a project the
        # collector is measuring has one — but it is a real behaviour change for
        # such a mission (a stale `latest_observations` latency or cost figure
        # stops being reported), so it is stated here and pinned by an example
        # in spec/services/system/fleet/sensors/project_slo_sensor_utilization_spec.rb.
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

          # Fall through to the config seam only when there is NO real
          # observation at all. `unavailable` metrics arrive as nil (skip
          # them); but a real 0 — e.g. replica_count 0 when nothing came up —
          # is a meaningful drift signal and must NOT be discarded.
          return nil if by_name.values.all?(&:nil?)

          {
            "availability_pct" => by_name["availability_pct"]&.to_f,
            "p99_latency_ms" => by_name["p99_latency_ms"]&.to_f,
            "month_to_date_cost_usd" => by_name["cost_usd_mtd"]&.to_f,
            "actual_replica_count" => by_name["replica_count"]&.to_i,
            "actual_region_count" => by_name["region_count"]&.to_i,
            # `&.to_f`, NEVER a bare `.to_f`. nil.to_f is 0.0 in Ruby, and 0.0
            # is a REAL, meaningful throughput reading here (tunnels up, no
            # traffic) — so a bare conversion would turn "the collector could
            # not measure this mission" into "this mission moved nothing",
            # which is the exact breach the floor below fires on. The safe
            # navigation IS the oracle; see the mutation spec in
            # spec/services/system/fleet/sensors/project_slo_sensor_spec.rb.
            "sdwan_throughput_bytes_per_s" => by_name["sdwan_throughput_bytes_per_s"]&.to_f,
            # IMP-7684d3f8658a — the two utilization metrics the collector has
            # produced since APO-2a and this sensor never read.
            #
            # `&.to_f` for the same reason as every row above, but state the
            # honest difference: on a CEILING the nil-vs-zero distinction is not
            # currently observable in a signal — an unmeasured nil and a
            # fabricated 0.0 both sit below every positive ceiling, and
            # Ai::Mission never resolves a non-positive one. It is kept because
            # this hash is the sensor's whole vocabulary of what was observed:
            # a 0.0 standing in for "we could not see the fleet" is wrong for
            # any reader that does not happen to be a ceiling comparison, and
            # the throughput FLOOR one row up is exactly such a reader.
            "cpu_pct" => by_name["cpu_pct"]&.to_f,
            "memory_pct" => by_name["memory_pct"]&.to_f
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
            "actual_region_count" => obs["actual_region_count"]&.to_i,
            # Same `&.` rule as the DB arm: a mission whose synthetic
            # observation blob omits throughput has not been measured, and
            # must not read as a floor breach.
            "sdwan_throughput_bytes_per_s" => obs["sdwan_throughput_bytes_per_s"]&.to_f,
            # Same `&.` rule again, and the same honest caveat as the DB arm:
            # an observation blob that omits a utilization metric has not
            # measured it, and nil is what this hash says about that.
            "cpu_pct" => obs["cpu_pct"]&.to_f,
            "memory_pct" => obs["memory_pct"]&.to_f
          }
        end

        # ----- signal builders ----------------------------------------------

        # `replica_count` rides along on both branches. An SLO breach's
        # `observed` is the breached METRIC (latency, availability), so a
        # consumer that needs to know how large the fleet currently is has no
        # way to get it from this payload — AdaptationProposerService has to
        # size a scale-out from the live count, and reading the metric rows
        # itself would both duplicate this sampler and make core depend on
        # this extension. Carrying it here keeps ONE reader of the telemetry,
        # so the sensor and the proposer cannot disagree about the fleet
        # within a single tick. It is nil when unobservable, and a consumer
        # must treat nil as "cannot see the fleet" rather than substituting a
        # declared/expected size.
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
                replica_count: obs["actual_replica_count"],
                correlation_id: correlation
              },
              fingerprint: "project_slo_violation:#{mission.id}:p99_latency_ms"
            )
          end

          # `!nil?`, not `.present?` — the SAME spelling the SDWAN throughput
          # floor below uses, for the same reason and now stated on both. These
          # are the sensor's only two FLOORS, and a floor is where the
          # absent-vs-zero distinction becomes observable: a measured 0.0 means
          # every replica that owes us a heartbeat has gone silent (a total
          # outage, the most severe thing this sensor says) while nil means the
          # collector could not measure availability at all, and rendering that
          # as 0% manufactures an outage that is not happening.
          #
          # `.present?` was CORRECT here — 0.0 is present in Ruby — but it is
          # the exact truthiness test the throughput floor's comment warns a
          # later reader against, and having one floor spell it defensively
          # while its sibling did not is what let that warning cover only half
          # of what it describes. Behaviour is unchanged; the pair below it in
          # project_slo_sensor_availability_spec.rb is what holds the line.
          #
          # The latency and cost arms deliberately keep `.present?`: they are
          # CEILINGS, where an unmeasured nil and a fabricated 0.0 both sit
          # below the threshold and produce the same outcome, so there is no
          # property to pin and changing them would be churn.
          if !obs["availability_pct"].nil? && obs["availability_pct"] < targets["availability_pct"]
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
                replica_count: obs["actual_replica_count"],
                correlation_id: correlation
              },
              fingerprint: "project_slo_violation:#{mission.id}:availability_pct"
            )
          end

          # IMP-25e75f960dee — the SDWAN throughput floor, the first consumer
          # of the per-peer WireGuard byte counters IMP-ab73cc2fca65 landed.
          # Third in the chain because this method returns the FIRST violated
          # metric and latency/availability remain the classic breaches.
          #
          # `!observed.nil?`, not `.present?`. 0.0 is a MEASURED value — a
          # mission whose tunnels carried nothing for the interval is precisely
          # the breach worth firing on — and nil means unmeasured. Both happen
          # to satisfy `.present?`/`.blank?` correctly today only by accident
          # of 0.0 being present in Ruby; spelling it nil-explicitly is what
          # stops a later reader "tidying" it into a truthiness test that
          # silently swallows the measured zero.
          #
          # The floor is only ever non-nil when the operator declared one, so
          # this branch is unreachable for every mission that hasn't opted in.
          floor = targets["min_throughput_bytes_per_s"]
          throughput = obs["sdwan_throughput_bytes_per_s"]
          if !floor.nil? && floor.positive? && !throughput.nil? && throughput < floor
            breach_pct = pct_under(throughput, floor)
            return build_signal(
              kind: "system.project_slo_violation",
              severity: severity_for(breach_pct),
              payload: {
                mission_id: mission.id,
                metric: "sdwan_throughput_bytes_per_s",
                observed: throughput,
                target: floor,
                breach_pct: breach_pct,
                replica_count: obs["actual_replica_count"],
                correlation_id: correlation
              },
              fingerprint: "project_slo_violation:#{mission.id}:sdwan_throughput_bytes_per_s"
            )
          end

          # IMP-7684d3f8658a — the utilization ceilings, LAST in the chain.
          # This method returns the FIRST violated metric, so appending rather
          # than inserting keeps every signal a mission emits today byte for
          # byte: a project that would have reported latency, availability or a
          # throughput floor still reports it, and cpu/memory only speak when
          # nothing louder did.
          UTILIZATION_METRICS.each do |metric, target_key|
            signal = utilization_signal(mission, targets, obs, correlation, metric, target_key)
            return signal if signal
          end

          nil
        end

        # A utilization CEILING breach: observed strictly above the declared
        # (or defaulted) percentage.
        #
        # `.nil?`-explicit on both sides, never `.present?` — as a statement of
        # intent, not because a signal can currently tell the two apart: on a
        # ceiling an unmeasured nil and a fabricated 0.0 both sit below every
        # positive target. What the explicit spelling buys is that the guard
        # keeps meaning "unmeasured" if this ever grows a floor-shaped sibling,
        # where the two answers diverge — which is exactly what happened to the
        # throughput check one screen up.
        #
        # `target <= 0` is unreachable through Ai::Mission#utilization_targets,
        # which resolves a non-positive declaration to nil. It is kept as the
        # local statement of what this method needs: a ceiling of 0 would fire
        # on every tick of every mission, so a future target source that does
        # not share that rule cannot turn this into a flood.
        def utilization_signal(mission, targets, obs, correlation, metric, target_key)
          target = targets[target_key]
          observed = obs[metric]
          return nil if target.nil? || target <= 0
          return nil if observed.nil? || observed <= target

          breach_pct = pct_over(observed, target)
          build_signal(
            kind: "system.project_slo_violation",
            severity: severity_for(breach_pct),
            payload: {
              mission_id: mission.id,
              metric: metric,
              observed: observed,
              target: target,
              breach_pct: breach_pct,
              replica_count: obs["actual_replica_count"],
              correlation_id: correlation
            },
            fingerprint: "project_slo_violation:#{mission.id}:#{metric}"
          )
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
