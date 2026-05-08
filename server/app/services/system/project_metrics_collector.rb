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

    # Discovers a sample for every known metric. Sensors will gracefully
    # ignore missing samples, so adding a metric here is forward-compatible.
    #
    # TODO(metrics-backend): Replace stub_sample with real per-instance
    # telemetry once the production metrics backend lands. Intended sources:
    #   - p99_latency_ms / availability_pct: SDWAN edge probes
    #   - cpu_pct / memory_pct: node agent heartbeat (FleetEvent payload)
    #   - replica_count / region_count: NodeInstance.where(mission scope)
    #   - cost_usd_mtd: billing engine MTD aggregation
    def sample_all
      METRIC_TYPE_MAP.keys.each_with_object({}) do |metric_name, samples|
        samples[metric_name] = sample_metric(metric_name)
      end
    end

    # Stub-sampler: records zero with a note flagging this as a placeholder.
    # Subclasses / replacement implementations should override this to read
    # from the real metrics backend.
    def sample_metric(metric_name)
      stub_sample(metric_name)
    end

    def stub_sample(metric_name)
      {
        "observed" => 0,
        "unit" => unit_for(metric_name),
        "source" => "stub",
        "note" => "TODO(metrics-backend): replace with real telemetry"
      }
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
