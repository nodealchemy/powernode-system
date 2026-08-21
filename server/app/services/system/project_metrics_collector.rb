# frozen_string_literal: true

module System
  # Periodic sampler for project (infrastructure-mission) metrics.
  #
  # Wired into `FleetAutonomyService.tick!` so each fleet autonomy cycle (60s)
  # writes a fresh batch of `System::ProjectMetric` rows for every active
  # infrastructure mission. `ProjectSloSensor` then queries the latest rows
  # per mission to evaluate SLO/drift/cost signals.
  #
  # The point of this slice is the **storage and query path** — production
  # samplers (cloud-provider Prometheus scrapers, billing API exporters,
  # NodeInstance health probes) will replace the stub-sampling logic with
  # real telemetry. Until they land, the collector records placeholder zero
  # values with a `note` field flagging the source as `stub` so dashboards
  # don't mistake them for real measurements.
  #
  # Usage:
  #   System::ProjectMetricsCollector.collect!(mission: mission)
  #   System::ProjectMetricsCollector.collect!(mission: mission, correlation_id: tick_correlation)
  class ProjectMetricsCollector
    # Mapping of metric_name → metric_type. Keeps the vocabulary in one
    # place; the sensor/collector contract relies on these being stable.
    METRIC_TYPE_MAP = {
      "p99_latency_ms"   => "latency",
      "availability_pct" => "latency",   # availability is co-evaluated w/ latency
      "cpu_pct"          => "utilization",
      "memory_pct"       => "utilization",
      "replica_count"    => "capacity",
      "region_count"     => "topology",
      "cost_usd_mtd"     => "cost"
    }.freeze

    # Class-level entry point — mirrors the FleetAutonomyService.tick! shape
    # so callers don't have to construct the collector directly.
    def self.collect!(mission:, correlation_id: nil)
      new(mission: mission, correlation_id: correlation_id).collect!
    end

    def initialize(mission:, correlation_id: nil)
      @mission = mission
      @correlation_id = correlation_id || build_correlation_id
    end

    # Samples each metric in METRIC_TYPE_MAP and writes one ProjectMetric row
    # per metric. Returns the array of created records.
    def collect!
      return [] unless valid_mission?

      sampled_at = Time.current
      samples = sample_all
      records = []

      ::System::ProjectMetric.transaction do
        samples.each do |metric_name, payload|
          records << ::System::ProjectMetric.create!(
            mission_id: @mission.id,
            metric_name: metric_name,
            metric_type: METRIC_TYPE_MAP.fetch(metric_name),
            value: payload,
            sampled_at: sampled_at,
            correlation_id: @correlation_id
          )
        end
      end

      records
    end

    private

    attr_reader :mission

    def valid_mission?
      return false if @mission.nil?
      return false unless @mission.respond_to?(:mission_type)
      @mission.mission_type.to_s == "infrastructure"
    end

    # Discovers a sample for every known metric. Sensors gracefully ignore
    # missing samples (observed: nil), so adding a metric here is
    # forward-compatible.
    #
    # Real sources are wired per-metric in `sample_metric`. Metrics whose
    # backend hasn't landed yet return an honest `unavailable` sample
    # (observed: nil) — never a fabricated zero (see `unavailable_sample`).
    # Intended sources for the still-unwired metrics:
    #   - p99_latency_ms / availability_pct: SDWAN edge probes (the
    #     Slo::TelemetryAdapter `metric.latency_ms` FleetEvent transport)
    #   - cpu_pct / memory_pct: node agent heartbeat (FleetEvent payload)
    #   - cost_usd_mtd: billing engine MTD aggregation
    def sample_all
      instance_ids = resolvable_instance_ids
      METRIC_TYPE_MAP.keys.each_with_object({}) do |metric_name, samples|
        samples[metric_name] = sample_metric(metric_name, instance_ids)
      end
    end

    # Per-metric dispatch. Each metric reads its real source where one is
    # wired; everything else returns an honest `unavailable` sample so the
    # SLO sensor skips it instead of reading a fabricated zero as a real
    # measurement. Wiring a new real source is a one-branch change here.
    def sample_metric(metric_name, instance_ids)
      case metric_name
      when "replica_count" then sample_replica_count(instance_ids)
      when "region_count"  then sample_region_count(instance_ids)
      else unavailable_sample(metric_name)
      end
    end

    # replica_count = instances this mission provisioned that the control plane
    # still expects to serve — NodeInstance::LIVE_REPLICA_STATUSES, which the
    # `live_replicas` scope is the single spelling of.
    #
    # `unavailable` when the mission has no resolvable instances (we genuinely
    # can't tell); a resolvable mission with zero live instances reports a real
    # 0 — a meaningful "nothing came up" drift signal, not a stub.
    #
    # IMP-797a87dbd0bd: this filtered on `where.not(status: "terminated")`
    # alone, so an `error` instance — a replica the platform had marked FAILED
    # — still counted as capacity. ProjectSloSensor#detect_drift only fires on
    # observed != expected, so a mission whose replica died reported its full
    # count and drifted silently, in exactly the case the signal exists for.
    #
    # Not `active`: that scope (pending/provisioning/running/stopped) also
    # drops `starting`/`rebooting`, which would make every routine reboot read
    # as capacity loss and provoke a replacement provision — trading a silent
    # failure for a noisy false one.
    def sample_replica_count(instance_ids)
      return unavailable_sample("replica_count") if instance_ids.empty?

      count = ::System::NodeInstance.where(id: instance_ids).live_replicas.count
      live_sample("replica_count", count)
    end

    # region_count = distinct provider regions across the mission's live
    # instances, on the SAME liveness definition as replica_count.
    #
    # Sharing it is the point: the two metrics are sampled from one instance
    # set in one tick and land in one observation hash, so a region_count that
    # counted errored rows while replica_count did not would describe two
    # different fleets in the same breath. Semantically it is also the right
    # filter on its own — a region whose only instance has errored is one the
    # mission no longer occupies, and reporting it as still-occupied overstates
    # geographic coverage the same way the replica count overstated capacity.
    def sample_region_count(instance_ids)
      return unavailable_sample("region_count") if instance_ids.empty?

      count = ::System::NodeInstance.where(id: instance_ids)
                                    .live_replicas
                                    .distinct.count(:provider_region_id)
      live_sample("region_count", count)
    end

    # A real measurement read from a wired backend.
    def live_sample(metric_name, observed)
      { "observed" => observed, "unit" => unit_for(metric_name), "source" => "live" }
    end

    # Honest stand-in for a metric whose telemetry backend isn't wired yet.
    # `observed: nil` (NOT 0) so ProjectSloSensor's `.present?` guards skip it
    # rather than treating a fabricated zero as a real sample. Replaces the
    # prior zero-valued stub, which risked false SLO/availability violations
    # the moment any single real metric was wired alongside it.
    def unavailable_sample(metric_name)
      {
        "observed" => nil,
        "unit" => unit_for(metric_name),
        "source" => "unavailable",
        "note" => "no telemetry backend wired for #{metric_name} yet (TODO metrics-backend)"
      }
    end

    # Resolves the NodeInstance ids this mission provisioned, via the
    # provisioning runner's recorded step outputs. The mission soft-links to
    # its Ai::GoalPlan through configuration["plan"]["plan_id"] (stamped by
    # PlanComposerService); each completed step records produced ids under
    # metadata["last_outputs"]["outputs"]["node_instance_ids"] — the same seam
    # the runner uses for cross-step data flow.
    #
    # THE WRITER HAS THREE SHAPES; THIS READS ALL OF THEM (IMP-9978fcf23a27).
    #
    # SkillCompositionRunner#result_outputs is
    #   result[:data] || result["data"] || result[:outputs] || result["outputs"] || result.to_h
    # and #record_outputs stores whatever that returns VERBATIM as
    # metadata["last_outputs"]. So the envelope decides the depth:
    #
    #   :data present  -> last_outputs is the payload; ids under its "outputs"
    #   :outputs only  -> last_outputs IS the outputs hash; ids at the TOP level
    #   neither        -> last_outputs is result.to_h; ids at the TOP level
    #
    # The nested level was wrong here until IMP-3431f73dabe6: digging the ids at
    # the top always returned nil, so this returned [], so replica_count and
    # region_count short-circuited to `unavailable` and ProjectSloSensor never
    # saw a live sample.
    #
    # WHAT THE ENUMERATION FOUND, recorded because the severity claim depends on
    # it: every executor SkillCompositionRunner.resolve_executor can reach today
    # — 58 under System::Ai::Skills, 2 under Ai::Skills, CrudFactory subclasses
    # included — returns BaseSkillExecutor#success, i.e. { success: true, data: }.
    # So the narrowed dig was NOT silently broken again; the other two branches
    # are live in the writer with no executor behind them. Reading all three is
    # hardening against the writer's actual contract rather than repair of an
    # active defect, and it is what stops the next executor that returns a bare
    # envelope from re-creating IMP-3431f73dabe6 in silence.
    #
    # deep_stringify_keys matches the sibling readers (VerificationService
    # #last_outputs, AdaptationDispatchService#produced_instance_ids), which all
    # normalize before digging; this reader was the only one that did not.
    #
    # Returns [] (never raises) so a mission without a resolvable plan
    # degrades to `unavailable`, not a false zero.
    def resolvable_instance_ids
      cfg = @mission.configuration
      plan_id = cfg.is_a?(Hash) ? cfg.dig("plan", "plan_id") : nil
      return [] if plan_id.blank?

      plan = ::Ai::GoalPlan.find_by(id: plan_id)
      return [] unless plan

      plan.steps.where(status: "completed").flat_map { |step|
        step_instance_ids(step)
      }.compact.uniq
    rescue StandardError => e
      Rails.logger.warn("[ProjectMetricsCollector] instance resolution failed for mission=#{@mission&.id}: #{e.class}: #{e.message}")
      []
    end

    # Both depths, unioned. Deduping is left to the single `.uniq` in the
    # caller, which already spans every step — a second one here would be a
    # redundant mechanism, and two guards for one property make a mutation test
    # unable to tell which of them is actually holding the line.
    def step_instance_ids(step)
      meta = step.metadata.is_a?(Hash) ? step.metadata : {}
      outs = meta["last_outputs"] || meta[:last_outputs] || {}
      return [] unless outs.is_a?(Hash)

      outs = outs.deep_stringify_keys
      Array(outs.dig("outputs", "node_instance_ids")) + Array(outs["node_instance_ids"])
    end

    def unit_for(metric_name)
      case metric_name
      when "p99_latency_ms" then "ms"
      when "availability_pct", "cpu_pct", "memory_pct" then "percent"
      when "replica_count", "region_count" then "count"
      when "cost_usd_mtd" then "usd"
      end
    end

    def build_correlation_id
      bucket = (Time.current.to_i / 60).to_s
      "project_metrics:#{@mission&.id}:#{bucket}"
    end
  end
end
